#!/usr/bin/env bash
# Bootstrap hub GitOps app-of-apps on cluster acm.
# Does NOT apply spoke workloads or mesh peering.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTEXT="${KUBE_CONTEXT:-acm}"
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/panchoraposo/demo-spring.git}"
TARGET_REVISION="${TARGET_REVISION:-main}"

echo "==> context=${CONTEXT} repo=${GIT_REPO_URL} revision=${TARGET_REVISION}"

if ! oc --context "${CONTEXT}" get deploy openshift-gitops-server -n openshift-gitops >/dev/null 2>&1; then
  echo "==> Installing OpenShift GitOps Operator subscription on acm"
  oc --context "${CONTEXT}" apply -f "${ROOT_DIR}/gitops/platform/operators/subscription-openshift-gitops.yaml"
  for i in $(seq 1 60); do
    if oc --context "${CONTEXT}" get deploy openshift-gitops-server -n openshift-gitops >/dev/null 2>&1; then
      oc --context "${CONTEXT}" -n openshift-gitops rollout status deploy/openshift-gitops-server --timeout=300s
      break
    fi
    sleep 10
  done
fi

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
sed -e "s|https://github.com/panchoraposo/demo-spring.git|${GIT_REPO_URL}|g" \
    -e "s|targetRevision: main|targetRevision: ${TARGET_REVISION}|g" \
    "${ROOT_DIR}/gitops/bootstrap/acm-root.yaml" > "${TMP}"

echo "==> Applying acm root Application"
oc --context "${CONTEXT}" apply -f "${TMP}" -n openshift-gitops

cat <<EOF

Hub bootstrap submitted on context ${CONTEXT}.

Prefer the full installer (env discovery, Argo cluster secrets, mesh, dashboard):
  cd ansible && ansible-playbook -i inventory.example.yml playbooks/install.yml

Manual next steps (when managed clusters are ready):
  1. Optional Gitea seed: scripts/bootstrap-gitea.sh
  2. Label ManagedClusters + register hub Argo cluster secrets, then:
       oc --context ${CONTEXT} apply -k gitops/acm
  3. Sync Conjur creds to managed clusters:
       scripts/sync-conjur-creds-to-clusters.sh
  4. Bootstrap Quay CI + pull secrets:
       scripts/bootstrap-quay-ci.sh
       scripts/sync-quay-pull-secret-to-clusters.sh
  5. Exchange mesh remote secrets:
       scripts/mesh/exchange-remote-secrets.sh

EOF
