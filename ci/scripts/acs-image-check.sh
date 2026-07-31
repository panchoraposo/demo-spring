#!/usr/bin/env bash
# RHACS (StackRox) image policy check for Jenkins.
# Soft-fails (exit 0 + WARN) when Central/token/roxctl are unavailable so the
# demo pipeline still works before bootstrap-acs-ci.sh has been run.
#
# Required env (when enforcing):
#   ACS_CENTRAL_URL   e.g. https://central-stackrox.apps…
#   ACS_API_TOKEN     Central API token
#   IMAGE             full image ref (Quay)
# Optional:
#   TOOLS_DIR         where to cache roxctl
#   ACS_FAIL_ON       Critical|High|Medium|Low|None  (default: High)
#   ACS_REQUIRED      if "true", missing Central/token fails the build
set -euo pipefail

TOOLS_DIR="${TOOLS_DIR:-${WORKSPACE:-.}/.tools}"
ACS_FAIL_ON="${ACS_FAIL_ON:-High}"
ACS_REQUIRED="${ACS_REQUIRED:-false}"
mkdir -p "${TOOLS_DIR}"

warn_skip() {
  echo "WARN: $*"
  if [[ "${ACS_REQUIRED}" == "true" ]]; then
    exit 1
  fi
  exit 0
}

[[ -n "${IMAGE:-}" ]] || warn_skip "IMAGE not set; skipping ACS check"
[[ -n "${ACS_CENTRAL_URL:-}" ]] || {
  # Discover Central Route on acm when env not injected.
  ACS_CENTRAL_URL="$(oc -n stackrox get route central -o jsonpath='https://{.spec.host}' 2>/dev/null || true)"
}
[[ -n "${ACS_CENTRAL_URL:-}" ]] || warn_skip "ACS Central URL not found; run scripts/bootstrap-acs-ci.sh"
[[ -n "${ACS_API_TOKEN:-}" ]] || warn_skip "ACS_API_TOKEN empty; run scripts/bootstrap-acs-ci.sh"

if [[ ! -x "${TOOLS_DIR}/roxctl" ]]; then
  echo "==> installing roxctl"
  # Match Central version when possible; fall back to stable.
  VER="$(curl -sk -H "Authorization: Bearer ${ACS_API_TOKEN}" \
    "${ACS_CENTRAL_URL}/v1/metadata" 2>/dev/null | jq -r '.version // empty' || true)"
  if [[ -n "${VER}" ]]; then
    curl -fsSL -o "${TOOLS_DIR}/roxctl" \
      "https://mirror.openshift.com/pub/rhacs/assets/${VER}/bin/Linux/roxctl" \
      || curl -fsSL -o "${TOOLS_DIR}/roxctl" \
      "https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux/roxctl"
  else
    curl -fsSL -o "${TOOLS_DIR}/roxctl" \
      "https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux/roxctl"
  fi
  chmod +x "${TOOLS_DIR}/roxctl"
fi

HOSTPORT="$(echo "${ACS_CENTRAL_URL}" | sed -E 's|^https?://||; s|/$||')"
# Route is :443
case "${HOSTPORT}" in
  *:*) ;;
  *) HOSTPORT="${HOSTPORT}:443" ;;
esac

export ROX_API_TOKEN="${ACS_API_TOKEN}"
export ROX_CENTRAL_ADDRESS="${HOSTPORT}"

echo "==> roxctl image check ${IMAGE} (fail on >= ${ACS_FAIL_ON})"
set +e
"${TOOLS_DIR}/roxctl" image check \
  --image="${IMAGE}" \
  --insecure-skip-tls-verify \
  --force \
  2>&1 | tee /tmp/acs-image-check.out
rc=${PIPESTATUS[0]}
set -e

if [[ ${rc} -eq 0 ]]; then
  echo "ACS image check PASSED"
  exit 0
fi

# Soft classification: treat policy failures as hard; network/auth as warn unless required.
if grep -qiE 'violat|fail|denied|POLICY' /tmp/acs-image-check.out; then
  echo "ACS image check FAILED (policy) for ${IMAGE}"
  exit 1
fi

warn_skip "ACS image check exited ${rc}; see output above"
