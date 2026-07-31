#!/usr/bin/env bash
# Print how to open Red Hat build of Perses dashboards on the ACM hub console.
#
# Perses is embedded in the OpenShift console (Observe → Dashboards (Perses)),
# not a standalone Route. Multi-cluster metrics come from hub promxy.
#
# Usage:
#   ./scripts/perses-url.sh
#   ./scripts/perses-url.sh open
set -euo pipefail

CTX="${HUB_CONTEXT:-acm}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need oc

console="$(oc --context "${CTX}" whoami --show-console 2>/dev/null || true)"
[[ -n "${console}" ]] || {
  echo "ERROR: cannot resolve OpenShift console URL for context ${CTX}" >&2
  exit 1
}

# Console plugin path (COO Monitoring UIPlugin with Perses enabled).
perses_path="/monitoring/dashboards"
url="${console%/}${perses_path}"

cat <<EOF
Perses (Red Hat build) — multi-cluster dashboards on ${CTX}
  Console:     ${console}
  Dashboards:  ${url}
  Menu:        Observe → Dashboards (Perses)

GitOps dashboards (project acm-observability):
  • Banking HTTP (multi-cluster)
  • Banking failover compare (east vs west)

Datasource: Promxy (east + west) → same federation as Kiali.
EOF

if [[ "${1:-}" == "open" ]]; then
  if command -v open >/dev/null; then
    open "${url}"
  else
    echo "(open not available — paste the Dashboards URL above)" >&2
  fi
fi
