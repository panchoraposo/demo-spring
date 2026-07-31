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
#   ACS_FAIL_ON       Critical|High|Medium|Low|None  (default: Critical)
#                     Compares against the TOTAL line from roxctl (policies with
#                     BREAKS BUILD still print; we gate the build on severity).
#   ACS_REQUIRED      if "true", missing Central/token fails the build
#   ACS_FORCE_SCAN    if "true", pass --force (bypass Central image cache)
set -euo pipefail

TOOLS_DIR="${TOOLS_DIR:-${WORKSPACE:-.}/.tools}"
ACS_FAIL_ON="${ACS_FAIL_ON:-Critical}"
ACS_REQUIRED="${ACS_REQUIRED:-false}"
ACS_FORCE_SCAN="${ACS_FORCE_SCAN:-false}"
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
  ACS_CENTRAL_URL="$(oc -n stackrox get route central -o jsonpath='https://{.spec.host}' 2>/dev/null || true)"
}
[[ -n "${ACS_CENTRAL_URL:-}" ]] || warn_skip "ACS Central URL not found; run scripts/bootstrap-acs-ci.sh"
[[ -n "${ACS_API_TOKEN:-}" ]] || warn_skip "ACS_API_TOKEN empty; run scripts/bootstrap-acs-ci.sh"

ROXCTL_OS=Linux
case "$(uname -s)" in Darwin) ROXCTL_OS=Darwin ;; esac

if [[ ! -x "${TOOLS_DIR}/roxctl" ]]; then
  echo "==> installing roxctl (${ROXCTL_OS})"
  VER="$(curl -sk -H "Authorization: Bearer ${ACS_API_TOKEN}" \
    "${ACS_CENTRAL_URL}/v1/metadata" 2>/dev/null \
    | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
  if [[ -n "${VER}" ]]; then
    curl -fsSL -o "${TOOLS_DIR}/roxctl" \
      "https://mirror.openshift.com/pub/rhacs/assets/${VER}/bin/${ROXCTL_OS}/roxctl" \
      || curl -fsSL -o "${TOOLS_DIR}/roxctl" \
      "https://mirror.openshift.com/pub/rhacs/assets/latest/bin/${ROXCTL_OS}/roxctl"
  else
    curl -fsSL -o "${TOOLS_DIR}/roxctl" \
      "https://mirror.openshift.com/pub/rhacs/assets/latest/bin/${ROXCTL_OS}/roxctl"
  fi
  chmod +x "${TOOLS_DIR}/roxctl"
fi

HOSTPORT="$(echo "${ACS_CENTRAL_URL}" | sed -E 's|^https?://||; s|/$||')"
case "${HOSTPORT}" in
  *:*) ;;
  *) HOSTPORT="${HOSTPORT}:443" ;;
esac

export ROX_API_TOKEN="${ACS_API_TOKEN}"
export ROX_ENDPOINT="${HOSTPORT}"
export ROX_CENTRAL_ADDRESS="${HOSTPORT}"

FORCE_ARGS=()
if [[ "${ACS_FORCE_SCAN}" == "true" ]]; then
  FORCE_ARGS+=(--force)
fi

echo "==> roxctl image check ${IMAGE} (fail on >= ${ACS_FAIL_ON}) @ ${HOSTPORT}"
set +e
"${TOOLS_DIR}/roxctl" image check \
  --image="${IMAGE}" \
  -e "${HOSTPORT}" \
  --insecure-skip-tls-verify \
  "${FORCE_ARGS[@]}" \
  2>&1 | tee /tmp/acs-image-check.out
rc=${PIPESTATUS[0]}
set -e

# Example: (TOTAL: 2, LOW: 1, MEDIUM: 0, HIGH: 1, CRITICAL: 0)
totals="$(grep -Eo '\(TOTAL:[[:space:]]*[0-9]+,[[:space:]]*LOW:[[:space:]]*[0-9]+,[[:space:]]*MEDIUM:[[:space:]]*[0-9]+,[[:space:]]*HIGH:[[:space:]]*[0-9]+,[[:space:]]*CRITICAL:[[:space:]]*[0-9]+\)' /tmp/acs-image-check.out | tail -1 || true)"
if [[ -n "${totals}" ]]; then
  echo "ACS policy summary: ${totals}"
fi

count_sev() {
  local sev="$1"
  echo "${totals}" | sed -n "s/.*${sev}:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -1
}

critical="$(count_sev CRITICAL)"; critical="${critical:-0}"
high="$(count_sev HIGH)"; high="${high:-0}"
medium="$(count_sev MEDIUM)"; medium="${medium:-0}"
low="$(count_sev LOW)"; low="${low:-0}"

severity_rank() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    none) echo 99 ;;
    critical) echo 3 ;;
    high) echo 2 ;;
    medium) echo 1 ;;
    low) echo 0 ;;
    *) echo 3 ;;
  esac
}

threshold="$(severity_rank "${ACS_FAIL_ON}")"
fail=0
if [[ "${threshold}" -le 3 && "${critical}" -gt 0 ]]; then fail=1; fi
if [[ "${threshold}" -le 2 && "${high}" -gt 0 ]]; then fail=1; fi
if [[ "${threshold}" -le 1 && "${medium}" -gt 0 ]]; then fail=1; fi
if [[ "${threshold}" -le 0 && "${low}" -gt 0 ]]; then fail=1; fi

if [[ -n "${totals}" ]]; then
  if [[ "${fail}" -eq 0 ]]; then
    echo "ACS image check PASSED (evaluated; fail-on=${ACS_FAIL_ON})"
    exit 0
  fi
  echo "ACS image check FAILED (severity >= ${ACS_FAIL_ON}) for ${IMAGE}"
  exit 1
fi

# No TOTAL line — fall back to roxctl exit code / transport errors.
if [[ ${rc} -eq 0 ]]; then
  echo "ACS image check PASSED"
  exit 0
fi

if grep -qiE 'connection refused|matcher is not initialized|Unavailable|FailedPrecondition|authentication handshake' /tmp/acs-image-check.out; then
  warn_skip "ACS image check exited ${rc} (scanner/Central not ready); see output above"
fi

echo "ACS image check FAILED for ${IMAGE} (roxctl exit ${rc})"
exit 1
