#!/usr/bin/env bash
# Exchange Istio remote secrets between east and west (multi-primary peering).
# Adapted from ossm3-ambient-mode peering flow. Run only when both clusters exist.
set -euo pipefail

EAST_CONTEXT="${EAST_CONTEXT:-east}"
WEST_CONTEXT="${WEST_CONTEXT:-west}"
ISTIO_NS="${ISTIO_NS:-istio-system}"

exchange() {
  local from_ctx="$1" to_ctx="$2" remote_name="$3"
  echo "==> Creating remote secret for ${from_ctx} on ${to_ctx} as ${remote_name}"
  if ! command -v istioctl >/dev/null 2>&1; then
    echo "istioctl not found; install Istio 1.30 client tools and retry." >&2
    exit 1
  fi
  istioctl create-remote-secret \
    --context "${from_ctx}" \
    --name "${from_ctx}" \
    | oc --context "${to_ctx}" apply -f -

  oc --context "${to_ctx}" -n "${ISTIO_NS}" label secret "istio-remote-secret-${from_ctx}" \
    istio/multiCluster=true kiali.io/multiCluster=true --overwrite || true
}

exchange "${EAST_CONTEXT}" "${WEST_CONTEXT}" "east"
exchange "${WEST_CONTEXT}" "${EAST_CONTEXT}" "west"

echo "Remote secrets exchanged. Verify: oc --context east -n ${ISTIO_NS} get secrets | grep remote"
echo "Optional: scripts/mesh/sync-kiali-multicluster-secrets.sh for hub Kiali."
