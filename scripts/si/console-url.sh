#!/usr/bin/env bash
# Print the Service Interconnect Network Observer console URL (west cluster).
# Analogue of hub Kiali for the mesh failover demo.
#
# Usage:
#   ./scripts/si/console-url.sh
#   ./scripts/si/console-url.sh open   # macOS: open in browser
set -euo pipefail

WEST_CONTEXT="${WEST_CONTEXT:-west}"
SI_NS="${SI_NS:-banking-si-apps}"
OBSERVER_NAME="${OBSERVER_NAME:-banking-si}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need oc

host="$(oc --context "${WEST_CONTEXT}" -n "${SI_NS}" get route \
  -l app.kubernetes.io/name=network-observer \
  -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"

if [[ -z "${host}" ]]; then
  # Operator-created route name pattern: <networkobserver>-network-observer
  host="$(oc --context "${WEST_CONTEXT}" -n "${SI_NS}" get route \
    "${OBSERVER_NAME}-network-observer" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
fi

if [[ -z "${host}" ]]; then
  host="$(oc --context "${WEST_CONTEXT}" -n "${SI_NS}" get route -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
fi

[[ -n "${host}" ]] || {
  echo "ERROR: no Network Observer Route in ${WEST_CONTEXT}/${SI_NS}" >&2
  echo "Ensure banking-si-interconnect synced and NetworkObserver/${OBSERVER_NAME} is Ready." >&2
  exit 1
}

url="https://${host}"
echo "${url}"

if [[ "${1:-}" == "open" ]]; then
  if command -v open >/dev/null; then
    open "${url}"
  else
    echo "(open not available — paste the URL above)" >&2
  fi
fi
