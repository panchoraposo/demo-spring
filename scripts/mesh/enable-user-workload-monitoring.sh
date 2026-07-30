#!/usr/bin/env bash
# Enable OpenShift user-workload monitoring on spokes so PodMonitors/ServiceMonitors
# for waypoints/ztunnel/istiod are scraped (required for Kiali traffic graphs).
set -euo pipefail

CONTEXTS="${CONTEXTS:-east west}"

for ctx in ${CONTEXTS}; do
  echo "==> ${ctx}: enableUserWorkload"
  oc --context "${ctx}" -n openshift-monitoring apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
  for ns in banking-apps ztunnel istio-system; do
    oc --context "${ctx}" label ns "${ns}" openshift.io/user-monitoring=true --overwrite >/dev/null
  done
  echo "    waiting for openshift-user-workload-monitoring pods..."
  for _ in $(seq 1 36); do
    ready="$(oc --context "${ctx}" -n openshift-user-workload-monitoring get pods --no-headers 2>/dev/null | grep -c Running || true)"
    [[ "${ready}" -ge 2 ]] && break
    sleep 5
  done
  oc --context "${ctx}" -n openshift-user-workload-monitoring get pods
done

echo "Done. Apply mesh PodMonitors (gitops/components/mesh/base/podmonitors.yaml) if not already synced."
