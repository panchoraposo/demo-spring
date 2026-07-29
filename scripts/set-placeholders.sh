#!/usr/bin/env bash
# Replace GIT_REPO_URL and CLUSTER_DOMAIN placeholders in-repo (commit the result).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIT_REPO_URL="${GIT_REPO_URL:?Set GIT_REPO_URL}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:?Set CLUSTER_DOMAIN}"

# Optional supply-chain URLs (export before running if known)
RHDA_BACKEND_URL="${RHDA_BACKEND_URL:-REPLACE_ME_RHDA_BACKEND_URL}"
OIDC_ISSUER_URL="${OIDC_ISSUER_URL:-REPLACE_ME_OIDC_ISSUER_URL}"

# Also rewrite any remaining CLUSTER_DOMAIN / supply-chain tokens
find "${ROOT_DIR}/gitops" "${ROOT_DIR}/ci" -type f \( -name '*.yaml' -o -name '*.yml' -o -name 'Jenkinsfile*' \) -print0 \
  | xargs -0 sed -i.bak \
      -e "s|GIT_REPO_URL|${GIT_REPO_URL}|g" \
      -e "s|CLUSTER_DOMAIN|${CLUSTER_DOMAIN}|g" \
      -e "s|REPLACE_ME_RHDA_BACKEND_URL|${RHDA_BACKEND_URL}|g" \
      -e "s|REPLACE_ME_OIDC_ISSUER_URL|${OIDC_ISSUER_URL}|g"

find "${ROOT_DIR}/gitops" "${ROOT_DIR}/ci" -name '*.bak' -delete

for f in "${ROOT_DIR}/devfile.yaml" "${ROOT_DIR}/.vscode/settings.json"; do
  [ -f "${f}" ] || continue
  sed -i.bak \
    -e "s|REPLACE_ME_RHDA_BACKEND_URL|${RHDA_BACKEND_URL}|g" \
    -e "s|REPLACE_ME_OIDC_ISSUER_URL|${OIDC_ISSUER_URL}|g" \
    "${f}"
  rm -f "${f}.bak"
done

# Also update helm values location URL if present
sed -i.bak "s|https://jenkins.CLUSTER_DOMAIN/|https://jenkins.${CLUSTER_DOMAIN}/|g" \
  "${ROOT_DIR}/gitops/components/jenkins/helm-values.yaml" 2>/dev/null || true
rm -f "${ROOT_DIR}/gitops/components/jenkins/helm-values.yaml.bak"

echo "Placeholders updated. Review with git diff and commit."
