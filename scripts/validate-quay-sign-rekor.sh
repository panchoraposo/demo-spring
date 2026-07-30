#!/usr/bin/env bash
# After Jenkins CI with Quay+RHTAS: verify image, SBOM, signature, attestation, Rekor entry.
set -euo pipefail

CTX="${CTX:-acm}"
APP="${1:-banking-service}"
TAG="${2:-}"
ORG="${QUAY_ORG:-banking}"
TOOLS="${TOOLS_DIR:-$(mktemp -d)}"
mkdir -p "${TOOLS}"
export PATH="${TOOLS}:${PATH}"

QUAY_HOST="$(oc --context "${CTX}" -n quay-enterprise get route -l quay-component=quay-app-route \
  -o jsonpath='{.items[0].spec.host}')"
if [[ -z "${QUAY_HOST}" ]]; then
  QUAY_HOST="$(oc --context "${CTX}" -n quay-enterprise get route banking-quay-quay \
    -o jsonpath='{.spec.host}')"
fi
[[ -n "${QUAY_HOST}" ]] || { echo "ERROR: Quay route not found" >&2; exit 1; }

if [[ -z "${TAG}" ]]; then
  TAG="$(oc --context "${CTX}" -n banking-apps get istag "${APP}" -o jsonpath='{.status.tags[0].tag}' 2>/dev/null || true)"
  # Prefer numeric jenkins build tags if present
  TAG="$(oc --context "${CTX}" -n banking-apps get istag -o name 2>/dev/null \
    | sed -n "s|.*/${APP}:||p" | grep -E '^[0-9]+$' | sort -n | tail -1 || true)"
fi
[[ -n "${TAG}" ]] || TAG=latest

IMAGE="${QUAY_HOST}/${ORG}/${APP}:${TAG}"
echo "Image under test: ${IMAGE}"

if [[ ! -x "${TOOLS}/cosign" ]]; then
  curl -fsSL "https://github.com/sigstore/cosign/releases/download/v2.4.3/cosign-linux-amd64" \
    -o "${TOOLS}/cosign"
  chmod +x "${TOOLS}/cosign"
fi
if [[ ! -x "${TOOLS}/rekor-cli" ]]; then
  curl -fsSL "https://github.com/sigstore/rekor/releases/download/v1.3.6/rekor-cli-linux-amd64" \
    -o "${TOOLS}/rekor-cli" 2>/dev/null || \
  curl -fsSL "https://github.com/sigstore/rekor/releases/download/v1.3.5/rekor-cli-linux-amd64" \
    -o "${TOOLS}/rekor-cli"
  chmod +x "${TOOLS}/rekor-cli"
fi

REKOR_URL="$(oc --context "${CTX}" -n trusted-artifact-signer get rekor -o jsonpath='{.items[0].status.url}')"
TUF_URL="$(oc --context "${CTX}" -n trusted-artifact-signer get tuf -o jsonpath='{.items[0].status.url}')"
FULCIO_URL="$(oc --context "${CTX}" -n trusted-artifact-signer get fulcio -o jsonpath='{.items[0].status.url}')"
echo "Rekor : ${REKOR_URL}"
echo "TUF   : ${TUF_URL}"
echo "Fulcio: ${FULCIO_URL}"

# Auth to Quay with robot secret if present
if oc --context "${CTX}" -n banking-ci get secret quay-ci >/dev/null 2>&1; then
  U="$(oc --context "${CTX}" -n banking-ci get secret quay-ci -o jsonpath='{.data.username}' | base64 -d)"
  P="$(oc --context "${CTX}" -n banking-ci get secret quay-ci -o jsonpath='{.data.password}' | base64 -d)"
  mkdir -p "${HOME}/.docker"
  AUTH="$(printf '%s:%s' "${U}" "${P}" | base64 | tr -d '\n')"
  printf '{"auths":{"%s":{"auth":"%s"}}}\n' "${QUAY_HOST}" "${AUTH}" > "${HOME}/.docker/config.json"
fi

export COSIGN_YES=true
cosign initialize --mirror "${TUF_URL}" --root "${TUF_URL}/root.json" || true

echo
echo "==> cosign tree (expect signature + attestation + sbom refs)"
cosign tree "${IMAGE}" || true

echo
echo "==> Verify signature (key-based CI)"
if oc --context "${CTX}" -n banking-ci get secret cosign-signing-key >/dev/null 2>&1; then
  oc --context "${CTX}" -n banking-ci get secret cosign-signing-key -o jsonpath='{.data.cosign\.pub}' \
    | base64 -d > "${TOOLS}/cosign.pub"
  cosign verify --key "${TOOLS}/cosign.pub" --rekor-url="${REKOR_URL}" "${IMAGE}" \
    && echo "OK: signature verified against cosign.pub + Rekor"
else
  echo "WARN: no cosign-signing-key; skip key verify"
fi

echo
echo "==> Verify SBOM attestation"
cosign verify-attestation --key "${TOOLS}/cosign.pub" --type cyclonedx \
  --rekor-url="${REKOR_URL}" "${IMAGE}" > "${TOOLS}/attestation.jsonl" 2>"${TOOLS}/attestation.err" \
  && echo "OK: cyclonedx attestation verified" \
  || { echo "WARN: verify-attestation failed"; cat "${TOOLS}/attestation.err" || true; }

if [[ -s "${TOOLS}/attestation.jsonl" ]]; then
  echo "==> SBOM predicate preview"
  python3 - <<'PY' "${TOOLS}/attestation.jsonl"
import json,sys
line=open(sys.argv[1]).readline()
payload=json.loads(line)
pred=payload.get("payload")
if isinstance(pred,str):
  import base64
  pred=json.loads(base64.b64decode(pred+'==='))
print(json.dumps({k:pred.get(k) for k in ("_type","predicateType","predicate") if k in pred} or pred, indent=2)[:1200])
PY
fi

echo
echo "==> Search Rekor for image digest"
DIGEST="$(cosign triangulate "${IMAGE}" 2>/dev/null | tail -1 || true)"
# Prefer digest from crane/skopeo via cosign
IMG_DIGEST="$(python3 - <<PY
import subprocess,json,os
img=os.environ["IMAGE"]
# cosign tree often prints sha256
print("")
PY
)"
export IMAGE
DIGEST="$(cosign triangulate --type digest "${IMAGE}" 2>/dev/null || true)"
echo "digest: ${DIGEST:-unknown}"

if [[ -n "${DIGEST}" ]]; then
  rekor-cli --rekor_server "${REKOR_URL}" search --sha "${DIGEST#sha256:}" 2>/dev/null \
    || rekor-cli --rekor_server "${REKOR_URL}" search --artifact <(echo -n "${DIGEST}") 2>/dev/null \
    || echo "NOTE: search by digest may require the hashedrekord UUID from cosign verify output above."
fi

echo
echo "Manual Rekor UI / API checks:"
echo "  Rekor URL : ${REKOR_URL}"
echo "  Search UI : $(oc --context "${CTX}" -n trusted-artifact-signer get route -l app.kubernetes.io/component=rekor-search-ui -o jsonpath='https://{.items[0].spec.host}' 2>/dev/null || echo n/a)"
echo "  cosign verify --rekor-url=${REKOR_URL} --key cosign.pub ${IMAGE}"
echo "  cosign verify-attestation --type cyclonedx --rekor-url=${REKOR_URL} --key cosign.pub ${IMAGE}"
echo "  rekor-cli --rekor_server ${REKOR_URL} get --uuid <uuid-from-verify>"
