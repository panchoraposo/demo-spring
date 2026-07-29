#!/usr/bin/env bash
# One-time per cluster: OVN-Kubernetes local gateway mode for Istio ambient kubelet probes.
# See https://istio.io/latest/docs/ambient/install/platform-prerequisites/
set -euo pipefail
CONTEXTS="${CONTEXTS:-east west}"
for ctx in ${CONTEXTS}; do
  echo "==> ${ctx}: set routingViaHost=true"
  oc --context "${ctx}" patch network.operator cluster --type=merge -p '{
    "spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}
  }'
done
echo "Done. Nodes may take a few minutes to reconcile OVN."
