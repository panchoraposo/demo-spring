#!/usr/bin/env bash
# Push image to Quay, generate SBOM, attach/attest, and sign with RHTAS/cosign.
# Expected Quay artifacts: image, sbom, attestation (.att), signature (.sig).
set -euo pipefail

APP="${APP:?}"
IMAGE_TAG="${IMAGE_TAG:?}"
APPS_NS="${APPS_NS:-banking-apps}"
QUAY_HOST="${QUAY_HOST:?}"
QUAY_ORG="${QUAY_ORG:-banking}"
TOOLS_DIR="${TOOLS_DIR:-${WORKSPACE:-.}/.tools}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${WORKSPACE:-.}/.ci-artifacts/${APP}}"

mkdir -p "${TOOLS_DIR}" "${ARTIFACT_DIR}"
export PATH="${TOOLS_DIR}:${PATH}"

INTERNAL_REF="${APPS_NS}/${APP}:${IMAGE_TAG}"
QUAY_IMAGE="${QUAY_HOST}/${QUAY_ORG}/${APP}:${IMAGE_TAG}"

install_tool() {
  local name="$1" url="$2"
  if [ ! -x "${TOOLS_DIR}/${name}" ]; then
    echo "Installing ${name}..."
    curl -fsSL "${url}" -o "/tmp/${name}.tgz"
    tar -xzf "/tmp/${name}.tgz" -C "${TOOLS_DIR}"
    # normalize binary name if archive nested
    if [ ! -x "${TOOLS_DIR}/${name}" ]; then
      find /tmp "${TOOLS_DIR}" -maxdepth 3 -type f -name "${name}" -executable 2>/dev/null \
        | head -1 | xargs -I{} cp {} "${TOOLS_DIR}/${name}" || true
    fi
    chmod +x "${TOOLS_DIR}/${name}" || true
  fi
}

# cosign + syft (SBOM). Prefer GitHub release binaries.
if [ ! -x "${TOOLS_DIR}/cosign" ]; then
  COSIGN_VER="${COSIGN_VER:-v2.4.3}"
  curl -fsSL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VER}/cosign-linux-amd64" \
    -o "${TOOLS_DIR}/cosign"
  chmod +x "${TOOLS_DIR}/cosign"
fi
if [ ! -x "${TOOLS_DIR}/syft" ]; then
  SYFT_VER="${SYFT_VER:-v1.19.0}"
  curl -fsSL "https://raw.githubusercontent.com/anchore/syft/main/install.sh" \
    | sh -s -- -b "${TOOLS_DIR}" "${SYFT_VER}"
fi

echo "==> Resolve internal image digest for ${INTERNAL_REF}"
DIGEST="$(oc get istag "${APP}:${IMAGE_TAG}" -n "${APPS_NS}" -o jsonpath='{.image.dockerImageReference}' | sed -E 's/.*@//')"
INTERNAL_PULL="$(oc registry info --internal)/${APPS_NS}/${APP}@${DIGEST}"
echo "Internal: ${INTERNAL_PULL}"
echo "Quay:     ${QUAY_IMAGE}"

echo "==> Auth to internal OpenShift registry (source) + Quay (dest)"
# Merge SA token for image-registry into docker config without wiping Quay robot auth.
REG_INTERNAL="$(oc registry info --internal)"
oc registry login --registry="${REG_INTERNAL}" --to="${HOME}/.docker/config.json" --insecure=true \
  || oc registry login --to="${HOME}/.docker/config.json" --insecure=true

echo "==> Mirror image to Quay"
# Prefer skopeo from PATH; fall back to oc image mirror
if command -v skopeo >/dev/null 2>&1; then
  skopeo copy --all \
    --src-tls-verify=false \
    --dest-tls-verify=false \
    "docker://${INTERNAL_PULL}" \
    "docker://${QUAY_IMAGE}"
else
  oc image mirror --insecure=true --filter-by-os='.*' "${INTERNAL_PULL}" "${QUAY_IMAGE}"
fi

echo "==> Generate CycloneDX SBOM"
syft "registry:${QUAY_IMAGE}" -o cyclonedx-json="${ARTIFACT_DIR}/sbom.cdx.json"
syft "registry:${QUAY_IMAGE}" -o spdx-json="${ARTIFACT_DIR}/sbom.spdx.json"

echo "==> Upload SBOM to Trusted Profile Analyzer (Trustify) when available"
# In CI we require the SBOM upload to succeed (so SBOM is left in TPA).
# Developers can override with TPA_UPLOAD_REQUIRED=false when running locally.
TPA_UPLOAD_REQUIRED="${TPA_UPLOAD_REQUIRED:-}"
if [ -z "${TPA_UPLOAD_REQUIRED}" ]; then
  if [ -n "${JENKINS_URL:-}" ] || [ -n "${BUILD_NUMBER:-}" ]; then
    TPA_UPLOAD_REQUIRED=true
  else
    TPA_UPLOAD_REQUIRED=false
  fi
fi

TPA_URL="${TPA_URL:-}"
if [ -z "${TPA_URL}" ] && oc -n trusted-profile-analyzer get route >/dev/null 2>&1; then
  # Prefer the Trustify server route (not RHDA backend).
  TPA_HOST="$(oc -n trusted-profile-analyzer get route -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.host}{"\t"}{.spec.to.name}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' '$3 != "rhda-backend" && $2 != "" { print $2; exit }' || true)"
  [ -n "${TPA_HOST}" ] && TPA_URL="https://${TPA_HOST}"
fi

if [ -z "${TPA_URL}" ]; then
  echo "WARN: TPA_URL not found; leaving SBOM in Quay only."
  if [ "${TPA_UPLOAD_REQUIRED}" = "true" ]; then
    echo "ERROR: TPA upload is required in CI but TPA_URL is unset (set TPA_URL or grant route read access)." >&2
    exit 1
  fi
else
  hdr_auth=()
  # Prefer pre-provided token, otherwise obtain a non-interactive OIDC token for CI.
  if [ -z "${TPA_TOKEN:-}" ]; then
    TPA_OIDC_CLIENT_ID="${TPA_OIDC_CLIENT_ID:-cli}"
    TPA_OIDC_CLIENT_SECRET="${TPA_OIDC_CLIENT_SECRET:-}"
    TPA_OIDC_SCOPES="${TPA_OIDC_SCOPES:-create:document read:document}"

    # Derive issuer from TPA_URL by default: https://sso.<apps-domain>/realms/trustify
    TPA_OIDC_ISSUER_URL="${TPA_OIDC_ISSUER_URL:-}"
    if [ -z "${TPA_OIDC_ISSUER_URL}" ]; then
      tpa_host="${TPA_URL#http://}"; tpa_host="${tpa_host#https://}"; tpa_host="${tpa_host%%/*}"
      if [[ "${tpa_host}" == server.* ]]; then
        sso_host="sso.${tpa_host#server.}"
      else
        # best-effort fallback (same base domain)
        sso_host="sso.${tpa_host#*.}"
      fi
      TPA_OIDC_ISSUER_URL="https://${sso_host}/realms/trustify"
    fi

    if [ -n "${TPA_OIDC_CLIENT_SECRET}" ]; then
      token_url="${TPA_OIDC_TOKEN_URL:-${TPA_OIDC_ISSUER_URL}/protocol/openid-connect/token}"
      token_http="$(curl -sk -o /tmp/tpa-oidc.json -w '%{http_code}' \
        -X POST "${token_url}" \
        -d 'grant_type=client_credentials' \
        -d "client_id=${TPA_OIDC_CLIENT_ID}" \
        -d "client_secret=${TPA_OIDC_CLIENT_SECRET}" \
        -d "scope=${TPA_OIDC_SCOPES}" || true)"
      # Jenkins controller image may not have python3; parse with sed.
      TPA_TOKEN="$(sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /tmp/tpa-oidc.json | head -1 || true)"
      if [ -z "${TPA_TOKEN}" ]; then
        err="$(sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /tmp/tpa-oidc.json | head -1 || true)"
        echo "WARN: Failed to obtain TPA token (HTTP ${token_http}) issuer=${TPA_OIDC_ISSUER_URL} err=${err}" >&2
        head -c 300 /tmp/tpa-oidc.json 2>/dev/null || true
        echo >&2
      fi
    else
      echo "WARN: Missing TPA_OIDC_CLIENT_SECRET; cannot obtain CI token for TPA upload." >&2
    fi
  fi

  [ -n "${TPA_TOKEN:-}" ] && hdr_auth+=( -H "Authorization: Bearer ${TPA_TOKEN}" )
  if [ "${TPA_UPLOAD_REQUIRED}" = "true" ] && [ -z "${TPA_TOKEN:-}" ]; then
    echo "ERROR: TPA upload is required but no TPA_TOKEN and no OIDC client secret available." >&2
    exit 1
  fi

  # Trustify 3.x: POST /api/v3/sbom (v2 only supports GET). Body is raw bytes.
  upload_url="${TPA_URL}/api/v3/sbom?format=cyclonedx&labels.labels.app=${APP}&labels.labels.tag=${IMAGE_TAG}"
  code="$(curl -sk -o /tmp/tpa-upload.json -w '%{http_code}' \
    -X POST "${upload_url}" \
    -H 'Content-Type: application/octet-stream' \
    --data-binary "@${ARTIFACT_DIR}/sbom.cdx.json" \
    "${hdr_auth[@]}" || true)"
  echo "TPA upload HTTP=${code} url=${upload_url}"
  if [ "${code}" != "200" ] && [ "${code}" != "201" ] && [ "${code}" != "202" ]; then
    echo "WARN: SBOM upload to TPA failed (HTTP ${code})." >&2
    head -c 400 /tmp/tpa-upload.json 2>/dev/null || true
    if [ "${TPA_UPLOAD_REQUIRED}" = "true" ]; then
      echo "ERROR: SBOM upload to TPA is required in CI." >&2
      exit 1
    fi
  else
    head -c 400 /tmp/tpa-upload.json 2>/dev/null || true
    echo
  fi
fi

# RHTAS env (optional keyless). Always set Rekor/TUF when available on-cluster.
if [ -z "${TUF_URL:-}" ] && oc get tuf -n trusted-artifact-signer >/dev/null 2>&1; then
  export TUF_URL
  TUF_URL="$(oc get tuf -n trusted-artifact-signer -o jsonpath='{.items[0].status.url}')"
fi
if [ -z "${REKOR_URL:-}" ] && oc get rekor -n trusted-artifact-signer >/dev/null 2>&1; then
  export REKOR_URL
  REKOR_URL="$(oc get rekor -n trusted-artifact-signer -o jsonpath='{.items[0].status.url}')"
fi
if [ -z "${FULCIO_URL:-}" ] && oc get fulcio -n trusted-artifact-signer >/dev/null 2>&1; then
  export FULCIO_URL
  FULCIO_URL="$(oc get fulcio -n trusted-artifact-signer -o jsonpath='{.items[0].status.url}')"
fi

export COSIGN_YES=true
# CI keys are generated with an empty password (bootstrap-quay-ci.sh).
export COSIGN_PASSWORD="${COSIGN_PASSWORD-}"
if [ -n "${TUF_URL:-}" ]; then
  export COSIGN_MIRROR="${TUF_URL}"
  export COSIGN_ROOT="${TUF_URL}/root.json"
  cosign initialize --mirror "${TUF_URL}" --root "${TUF_URL}/root.json" || true
fi

sign_args=()
attest_args=()
if [ -n "${REKOR_URL:-}" ]; then
  sign_args+=(--rekor-url="${REKOR_URL}")
  attest_args+=(--rekor-url="${REKOR_URL}")
fi

# Prefer key-based CI signing (secret cosign-signing-key); fall back to keyless OIDC.
if [ -n "${COSIGN_PRIVATE_KEY:-}" ] || [ -f "${COSIGN_KEY_PATH:-/var/run/secrets/cosign/cosign.key}" ]; then
  KEY_PATH="${COSIGN_KEY_PATH:-/var/run/secrets/cosign/cosign.key}"
  if [ -n "${COSIGN_PRIVATE_KEY:-}" ]; then
    KEY_PATH="$(mktemp)"
    printf '%s' "${COSIGN_PRIVATE_KEY}" > "${KEY_PATH}"
  fi
  echo "==> Sign image (cosign key + RHTAS Rekor when configured)"
  cosign sign "${sign_args[@]}" --key "${KEY_PATH}" "${QUAY_IMAGE}"
  echo "==> Attach SBOM as OCI artifact"
  cosign attach sbom --sbom "${ARTIFACT_DIR}/sbom.cdx.json" --type cyclonedx "${QUAY_IMAGE}" || \
    cosign attach sbom --sbom "${ARTIFACT_DIR}/sbom.cdx.json" "${QUAY_IMAGE}"
  echo "==> Attest SBOM (in-toto / cyclonedx)"
  cosign attest "${attest_args[@]}" --key "${KEY_PATH}" \
    --type cyclonedx --predicate "${ARTIFACT_DIR}/sbom.cdx.json" "${QUAY_IMAGE}"
else
  echo "==> Sign image (keyless via RHTAS Fulcio)"
  : "${FULCIO_URL:?FULCIO_URL or COSIGN_PRIVATE_KEY required for signing}"
  : "${COSIGN_OIDC_ISSUER:=${OIDC_ISSUER_URL:-}}"
  cosign sign "${sign_args[@]}" \
    --fulcio-url="${FULCIO_URL}" \
    --oidc-issuer="${COSIGN_OIDC_ISSUER}" \
    ${COSIGN_IDENTITY_TOKEN:+--identity-token="${COSIGN_IDENTITY_TOKEN}"} \
    "${QUAY_IMAGE}"
  cosign attach sbom --sbom "${ARTIFACT_DIR}/sbom.cdx.json" --type cyclonedx "${QUAY_IMAGE}" || true
  cosign attest "${attest_args[@]}" \
    --fulcio-url="${FULCIO_URL}" \
    --oidc-issuer="${COSIGN_OIDC_ISSUER}" \
    ${COSIGN_IDENTITY_TOKEN:+--identity-token="${COSIGN_IDENTITY_TOKEN}"} \
    --type cyclonedx --predicate "${ARTIFACT_DIR}/sbom.cdx.json" "${QUAY_IMAGE}"
fi

echo "==> Quay artifact tree"
cosign tree "${QUAY_IMAGE}" || true

echo "QUAY_IMAGE=${QUAY_IMAGE}" > "${ARTIFACT_DIR}/quay.env"
echo "Signed/attested ${QUAY_IMAGE} (image + sbom + attestation + signature)."
