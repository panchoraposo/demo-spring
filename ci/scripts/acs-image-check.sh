#!/usr/bin/env bash
# RHACS policy check via `roxctl image check` (build-time policies).
#
# Required env:
#   ACS_CENTRAL_URL, ACS_API_TOKEN, IMAGE
# Optional:
#   TOOLS_DIR
#   ACS_FAIL_ON       Critical|High|Medium|Low|None  (default: Critical)
#                     Policy severities from the TOTAL line.
#   ACS_REQUIRED      if "true", missing Central/token fails the build
#   ACS_FORCE_SCAN    if "true", pass --force
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/ci/scripts/lib/acs-common.sh"

TOOLS_DIR="${TOOLS_DIR:-${WORKSPACE:-.}/.tools}"
ACS_FAIL_ON="${ACS_FAIL_ON:-Critical}"
ACS_REQUIRED="${ACS_REQUIRED:-false}"
ACS_FORCE_SCAN="${ACS_FORCE_SCAN:-false}"
OUT="${ACS_CHECK_OUT:-/tmp/acs-image-check.out}"

[[ -n "${IMAGE:-}" ]] || acs_warn_skip "IMAGE not set; skipping ACS policy check"
acs_resolve_central
acs_ensure_roxctl
acs_export_rox_env

FORCE_ARGS=()
if [[ "${ACS_FORCE_SCAN}" == "true" ]]; then
  FORCE_ARGS+=(--force)
fi

echo "==> roxctl image check ${IMAGE} (policies; fail on >= ${ACS_FAIL_ON}) @ ${ACS_HOSTPORT}"
set +e
"${TOOLS_DIR}/roxctl" image check \
  --image="${IMAGE}" \
  -e "${ACS_HOSTPORT}" \
  --insecure-skip-tls-verify \
  "${FORCE_ARGS[@]}" \
  2>&1 | tee "${OUT}"
rc=${PIPESTATUS[0]}
set -e

# Example: (TOTAL: 2, LOW: 1, MEDIUM: 0, HIGH: 1, CRITICAL: 0)
totals="$(grep -Eo '\(TOTAL:[[:space:]]*[0-9]+,[[:space:]]*LOW:[[:space:]]*[0-9]+,[[:space:]]*MEDIUM:[[:space:]]*[0-9]+,[[:space:]]*HIGH:[[:space:]]*[0-9]+,[[:space:]]*CRITICAL:[[:space:]]*[0-9]+\)' "${OUT}" | tail -1 || true)"
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
    echo "ACS policy check PASSED (evaluated; fail-on=${ACS_FAIL_ON})"
    exit 0
  fi
  echo "ACS policy check FAILED (severity >= ${ACS_FAIL_ON}) for ${IMAGE}"
  exit 1
fi

if [[ ${rc} -eq 0 ]]; then
  echo "ACS policy check PASSED"
  exit 0
fi

if grep -qiE 'connection refused|matcher is not initialized|Unavailable|FailedPrecondition|authentication handshake' "${OUT}"; then
  acs_warn_skip "ACS policy check exited ${rc} (scanner/Central not ready); see output above"
fi

echo "ACS policy check FAILED for ${IMAGE} (roxctl exit ${rc})"
exit 1
