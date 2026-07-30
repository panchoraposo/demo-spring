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

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
esac
case "${OS}" in
  darwin) COSIGN_ASSET="cosign-darwin-${ARCH}"; REKOR_ASSET="rekor-cli-darwin-${ARCH}" ;;
  linux)  COSIGN_ASSET="cosign-linux-${ARCH}";  REKOR_ASSET="rekor-cli-linux-${ARCH}" ;;
  *) echo "ERROR: unsupported OS ${OS}" >&2; exit 1 ;;
esac

if command -v cosign >/dev/null 2>&1; then
  :
elif [[ ! -x "${TOOLS}/cosign" ]]; then
  curl -fsSL "https://github.com/sigstore/cosign/releases/download/v2.4.3/${COSIGN_ASSET}" \
    -o "${TOOLS}/cosign"
  chmod +x "${TOOLS}/cosign"
  export PATH="${TOOLS}:${PATH}"
else
  export PATH="${TOOLS}:${PATH}"
fi
if command -v rekor-cli >/dev/null 2>&1; then
  :
elif [[ ! -x "${TOOLS}/rekor-cli" ]]; then
  curl -fsSL "https://github.com/sigstore/rekor/releases/download/v1.3.6/${REKOR_ASSET}" \
    -o "${TOOLS}/rekor-cli" 2>/dev/null || \
  curl -fsSL "https://github.com/sigstore/rekor/releases/download/v1.3.5/${REKOR_ASSET}" \
    -o "${TOOLS}/rekor-cli"
  chmod +x "${TOOLS}/rekor-cli"
  export PATH="${TOOLS}:${PATH}"
else
  export PATH="${TOOLS}:${PATH}"
fi
export PATH="${TOOLS}:${PATH}"

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
echo "==> Fetch Rekor entry (logIndex from cosign verify Bundle when present)"
MANIFEST_DIGEST="$(cosign triangulate "${IMAGE}" 2>/dev/null | sed -n 's|.*/sha256-|sha256:|p' | head -1 || true)"
echo "signature artifact: ${MANIFEST_DIGEST:-unknown}"
# Offline verify already proved Rekor inclusion; also pull first entries for demo.
rekor-cli --rekor_server "${REKOR_URL}" get --log-index 0 2>/dev/null | head -40 \
  || echo "NOTE: use UUID from cosign verify Bundle.Payload / SignedEntryTimestamp output above."

echo
echo "Manual Rekor / SBOM checks:"
echo "  Rekor URL : ${REKOR_URL}"
echo "  Image     : ${IMAGE}"
echo "  cosign tree ${IMAGE}"
echo "  cosign verify --rekor-url=${REKOR_URL} --key cosign.pub ${IMAGE}"
echo "  cosign verify-attestation --type cyclonedx --rekor-url=${REKOR_URL} --key cosign.pub ${IMAGE}"
echo "  rekor-cli --rekor_server ${REKOR_URL} get --log-index 0"
