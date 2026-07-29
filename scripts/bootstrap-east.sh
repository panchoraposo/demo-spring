#!/usr/bin/env bash
# Bootstrap the banking demo on OpenShift cluster east.
# Prerequisites: oc logged in; cluster-admin; pull secret for registry.redhat.io
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GIT_REPO_URL="${GIT_REPO_URL:?Set GIT_REPO_URL to this repository clone URL}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:?Set CLUSTER_DOMAIN to your apps domain (e.g. apps.east.example.com)}"
TARGET_REVISION="${TARGET_REVISION:-main}"

echo "==> Using GIT_REPO_URL=${GIT_REPO_URL}"
echo "==> Using CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"

if ! oc get csv -n openshift-gitops 2>/dev/null | grep -q gitops; then
  echo "==> Installing OpenShift GitOps Operator subscription"
  oc apply -f "${ROOT_DIR}/gitops/platform/operators/subscription-openshift-gitops.yaml"
  echo "    Waiting for openshift-gitops namespace..."
  oc new-project openshift-gitops --skip-config-write >/dev/null 2>&1 || true
  for i in $(seq 1 60); do
    if oc get deploy openshift-gitops-server -n openshift-gitops >/dev/null 2>&1; then
      oc -n openshift-gitops rollout status deploy/openshift-gitops-server --timeout=300s
      break
    fi
    sleep 10
  done
fi

echo "==> Rendering placeholders into a temporary bootstrap directory"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
cp -R "${ROOT_DIR}/gitops" "${TMP_DIR}/gitops"
cp -R "${ROOT_DIR}/ci" "${TMP_DIR}/ci"

# Replace placeholders for local apply of the root app only.
# Component manifests in Git should be updated via commit (or a follow-up PR).
find "${TMP_DIR}" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 \
  | xargs -0 sed -i.bak \
      -e "s|GIT_REPO_URL|${GIT_REPO_URL}|g" \
      -e "s|CLUSTER_DOMAIN|${CLUSTER_DOMAIN}|g" \
      -e "s|targetRevision: main|targetRevision: ${TARGET_REVISION}|g"
find "${TMP_DIR}" -name '*.bak' -delete

echo "==> Applying root Application (app-of-apps)"
oc apply -f "${TMP_DIR}/gitops/bootstrap/root-app.yaml"

cat <<EOF

Bootstrap submitted.

Next steps:
  1. Commit CLUSTER_DOMAIN / GIT_REPO_URL replacements into the Git repo so Argo CD
     can sync components without placeholders:
       find gitops ci -type f -name '*.yaml' | xargs sed -i '' \\
         -e 's|GIT_REPO_URL|${GIT_REPO_URL}|g' \\
         -e 's|CLUSTER_DOMAIN|${CLUSTER_DOMAIN}|g'
       git commit / push

  2. Watch applications:
       oc get applications -n openshift-gitops

  3. Open Argo CD console:
       oc get route openshift-gitops-server -n openshift-gitops

  4. After Keycloak is Ready, obtain a token and call the gateway:
       See docs/getting-started.md

EOF
