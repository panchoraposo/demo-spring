#!/usr/bin/env bash
# Create kubeconfig Secrets on acm for Kiali multi-cluster autodetect.
# Uses a dedicated cluster-admin reader SA on each spoke (istioctl's
# istio-reader SA is too limited for Kiali cache + graph).
set -euo pipefail

HUB_CONTEXT="${HUB_CONTEXT:-acm}"
SPOKE_CONTEXTS="${SPOKE_CONTEXTS:-east west}"
KIALI_NS="${KIALI_NS:-istio-system}"
READER_SA="${READER_SA:-kiali-remote-reader}"
TOKEN_DURATION="${TOKEN_DURATION:-8760h}"

oc --context "${HUB_CONTEXT}" create namespace "${KIALI_NS}" --dry-run=client -o yaml \
  | oc --context "${HUB_CONTEXT}" apply -f -

for ctx in ${SPOKE_CONTEXTS}; do
  echo "==> Preparing ${READER_SA} on ${ctx}"
  oc --context "${ctx}" -n "${KIALI_NS}" create sa "${READER_SA}" --dry-run=client -o yaml \
    | oc --context "${ctx}" apply -f -
  oc --context "${ctx}" adm policy add-cluster-role-to-user cluster-admin \
    "system:serviceaccount:${KIALI_NS}:${READER_SA}" >/dev/null

  SERVER="$(oc --context "${ctx}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  TOKEN="$(oc --context "${ctx}" -n "${KIALI_NS}" create token "${READER_SA}" --duration="${TOKEN_DURATION}")"

  echo "==> Installing Kiali remote secret for ${ctx} on ${HUB_CONTEXT}"
  cat <<EOF | oc --context "${HUB_CONTEXT}" -n "${KIALI_NS}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: istio-remote-secret-${ctx}
  namespace: ${KIALI_NS}
  labels:
    kiali.io/multiCluster: "true"
stringData:
  ${ctx}: |
    apiVersion: v1
    kind: Config
    clusters:
    - cluster:
        server: ${SERVER}
        insecure-skip-tls-verify: true
      name: ${ctx}
    contexts:
    - context:
        cluster: ${ctx}
        user: ${ctx}
      name: ${ctx}
    current-context: ${ctx}
    users:
    - name: ${ctx}
      user:
        token: ${TOKEN}
EOF
done

echo "Done. Kiali clustering.autodetect_secrets.label=kiali.io/multiCluster=true"
echo "Restart Kiali if clusters were already loaded: oc --context ${HUB_CONTEXT} -n ${KIALI_NS} delete pod -l app.kubernetes.io/name=kiali"
