#!/usr/bin/env bash
# RHACS vulnerability scan (CVEs) via `roxctl image scan`.
#
# Required env:
#   ACS_CENTRAL_URL, ACS_API_TOKEN, IMAGE
# Optional:
#   TOOLS_DIR
#   ACS_REQUIRED              fail if Central/token missing (default false)
#   ACS_SCAN_FAIL_ON          Critical|Important|Moderate|Low|None (default: None)
#                             RHACS CVE severities. Default None = report CVEs without
#                             failing the build (policy stage is the usual gate).
#   ACS_FORCE_SCAN            if true, --force
#   ACS_SCAN_SEVERITIES       comma list (default CRITICAL,IMPORTANT,MODERATE,LOW)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/ci/scripts/lib/acs-common.sh"

TOOLS_DIR="${TOOLS_DIR:-${WORKSPACE:-.}/.tools}"
ACS_REQUIRED="${ACS_REQUIRED:-false}"
ACS_SCAN_FAIL_ON="${ACS_SCAN_FAIL_ON:-None}"
ACS_FORCE_SCAN="${ACS_FORCE_SCAN:-false}"
ACS_SCAN_SEVERITIES="${ACS_SCAN_SEVERITIES:-CRITICAL,IMPORTANT,MODERATE,LOW}"
OUT="${ACS_SCAN_OUT:-/tmp/acs-image-scan.out}"
CSV="${ACS_SCAN_CSV:-${OUT}.csv}"

[[ -n "${IMAGE:-}" ]] || acs_warn_skip "IMAGE not set; skipping ACS vulnerability scan"
acs_resolve_central
acs_ensure_roxctl
acs_export_rox_env

FORCE_ARGS=()
if [[ "${ACS_FORCE_SCAN}" == "true" ]]; then
  FORCE_ARGS+=(--force)
fi

echo "==> roxctl image scan ${IMAGE} (CVEs; fail on >= ${ACS_SCAN_FAIL_ON}) @ ${ACS_HOSTPORT}"

# CSV for accurate severity counts (single Scanner round-trip for gating).
set +e
"${TOOLS_DIR}/roxctl" image scan \
  --image="${IMAGE}" \
  -e "${ACS_HOSTPORT}" \
  --insecure-skip-tls-verify \
  -o csv \
  --severity="${ACS_SCAN_SEVERITIES}" \
  "${FORCE_ARGS[@]}" \
  >"${CSV}" 2>"${OUT}.err"
rc=${PIPESTATUS[0]}
set -e

if grep -qiE 'connection refused|matcher is not initialized|Unavailable|FailedPrecondition|authentication handshake' "${OUT}.err" "${CSV}" 2>/dev/null; then
  cat "${OUT}.err" || true
  acs_warn_skip "ACS vulnerability scan exited ${rc} (scanner/Central not ready)"
fi

# Pretty table for the Jenkins log (Central usually caches after the CSV call).
set +e
"${TOOLS_DIR}/roxctl" image scan \
  --image="${IMAGE}" \
  -e "${ACS_HOSTPORT}" \
  --insecure-skip-tls-verify \
  -o table \
  --severity="${ACS_SCAN_SEVERITIES}" \
  2>&1 | tee "${OUT}"
set -e

count_csv() {
  local label="$1"
  # Skip header; SEVERITY is 4th field.
  awk -F',' -v s="${label}" '
    NR==1 && toupper($4) ~ /SEVERITY/ { next }
    {
      sev=$4; gsub(/"/,"",sev); gsub(/^[ \t]+|[ \t]+$/,"",sev);
      if (toupper(sev)==s) c++
    }
    END { print c+0 }
  ' "${CSV}" 2>/dev/null || echo 0
}

critical="$(count_csv CRITICAL)"
important="$(count_csv IMPORTANT)"
moderate="$(count_csv MODERATE)"
low="$(count_csv LOW)"

echo "ACS CVE summary: CRITICAL=${critical} IMPORTANT=${important} MODERATE=${moderate} LOW=${low}"

rank() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    none) echo 99 ;;
    critical) echo 3 ;;
    important) echo 2 ;;
    moderate) echo 1 ;;
    low) echo 0 ;;
    *) echo 3 ;;
  esac
}

threshold="$(rank "${ACS_SCAN_FAIL_ON}")"
fail=0
if [[ "${threshold}" -le 3 && "${critical}" -gt 0 ]]; then fail=1; fi
if [[ "${threshold}" -le 2 && "${important}" -gt 0 ]]; then fail=1; fi
if [[ "${threshold}" -le 1 && "${moderate}" -gt 0 ]]; then fail=1; fi
if [[ "${threshold}" -le 0 && "${low}" -gt 0 ]]; then fail=1; fi

if [[ "${fail}" -eq 0 ]]; then
  if [[ ${rc} -ne 0 ]] && [[ ! -s "${CSV}" ]]; then
    cat "${OUT}.err" || true
    acs_warn_skip "ACS vulnerability scan exited ${rc}; see output above"
  fi
  echo "ACS vulnerability scan PASSED (fail-on=${ACS_SCAN_FAIL_ON})"
  exit 0
fi

echo "ACS vulnerability scan FAILED (severity >= ${ACS_SCAN_FAIL_ON}) for ${IMAGE}"
exit 1
