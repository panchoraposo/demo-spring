#!/usr/bin/env bash
# Register a Gitea push webhook that pings Jenkins git/notifyCommit so CI starts
# quickly after Dev Spaces (or local) pushes to banking/demo-spring.
set -euo pipefail

ACM_CONTEXT="${ACM_CONTEXT:-acm}"
GITEA_NS="${GITEA_NS:-banking-git}"
CI_NS="${CI_NS:-banking-ci}"
ORG="${GITEA_ORG:-banking}"
REPO="${GITEA_REPO:-demo-spring}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need oc; need curl; need jq

GITEA_HOST="$(oc --context "${ACM_CONTEXT}" -n "${GITEA_NS}" get route gitea -o jsonpath='{.spec.host}')"
JENKINS_HOST="$(oc --context "${ACM_CONTEXT}" -n "${CI_NS}" get route jenkins -o jsonpath='{.spec.host}')"
REPO_URL="https://${GITEA_HOST}/${ORG}/${REPO}.git"
NOTIFY_URL="https://${JENKINS_HOST}/git/notifyCommit?url=${REPO_URL}"

ADMIN_USER="${ADMIN_USER:-gitea_admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-BankingGiteaChangeMe!}"

echo "==> creating Gitea admin token for webhook"
TOKEN_RESP="$(curl -sk -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
  -H 'Content-Type: application/json' \
  -X POST \
  -d "{\"name\":\"jenkins-webhook-$(date +%s)\",\"scopes\":[\"write:repository\"]}" \
  "https://${GITEA_HOST}/api/v1/users/${ADMIN_USER}/tokens")"
ADMIN_TOKEN="$(echo "${TOKEN_RESP}" | jq -r '.sha1 // empty')"
[[ -n "${ADMIN_TOKEN}" ]] || { echo "ERROR: could not create Gitea token: ${TOKEN_RESP}" >&2; exit 1; }

echo "==> listing existing hooks"
HOOKS="$(curl -sk -H "Authorization: token ${ADMIN_TOKEN}" \
  "https://${GITEA_HOST}/api/v1/repos/${ORG}/${REPO}/hooks")"
EXISTING="$(echo "${HOOKS}" | jq -r --arg u "${NOTIFY_URL}" '.[] | select(.config.url==$u) | .id' | head -1 || true)"
if [[ -n "${EXISTING}" ]]; then
  echo "  webhook already present (id=${EXISTING})"
else
  echo "==> creating webhook → ${NOTIFY_URL}"
  curl -sk -H "Authorization: token ${ADMIN_TOKEN}" \
    -H 'Content-Type: application/json' \
    -X POST \
    -d "{\"type\":\"gitea\",\"active\":true,\"events\":[\"push\"],\"config\":{\"url\":\"${NOTIFY_URL}\",\"content_type\":\"json\",\"http_method\":\"GET\"}}" \
    "https://${GITEA_HOST}/api/v1/repos/${ORG}/${REPO}/hooks" | jq '{id,active,events,url:.config.url}'
fi

echo
echo "Done."
echo "  Gitea repo: ${REPO_URL}"
echo "  Jenkins notify: ${NOTIFY_URL}"
echo "  (SCM poll H/1 remains as fallback)"
