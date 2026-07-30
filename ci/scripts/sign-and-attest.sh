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
