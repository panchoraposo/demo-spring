#!/usr/bin/env bash
# Create kubeconfig Secrets on acm for Kiali multi-cluster autodetect.
set -euo pipefail

HUB_CONTEXT="${HUB_CONTEXT:-acm}"
SPOKE_CONTEXTS="${SPOKE_CONTEXTS:-east west}"
KIALI_NS="${KIALI_NS:-istio-system}"

oc --context "${HUB_CONTEXT}" create namespace "${KIALI_NS}" --dry-run=client -o yaml \
  | oc --context "${HUB_CONTEXT}" apply -f -

for ctx in ${SPOKE_CONTEXTS}; do
  echo "==> Installing Kiali remote secret for ${ctx} on ${HUB_CONTEXT}"
  # Prefer istioctl; fall back to extracting kubeconfig cluster entry
  if command -v istioctl >/dev/null 2>&1; then
    istioctl create-remote-secret --context "${ctx}" --name "${ctx}" \
      | oc --context "${HUB_CONTEXT}" -n "${KIALI_NS}" apply -f -
  else
    echo "WARN: istioctl missing; create Secret ${ctx} manually with kubeconfig key." >&2
    continue
  fi
  oc --context "${HUB_CONTEXT}" -n "${KIALI_NS}" label secret "istio-remote-secret-${ctx}" \
    kiali.io/multiCluster=true --overwrite || \
  oc --context "${HUB_CONTEXT}" -n "${KIALI_NS}" label secret "${ctx}" \
    kiali.io/multiCluster=true --overwrite || true
done

echo "Done. Kiali clustering.autodetect_secrets.label=kiali.io/multiCluster=true"
