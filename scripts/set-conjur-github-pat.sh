#!/usr/bin/env bash
# Load a Git (Gitea) PAT into Conjur (banking/github-ci/*), force ESO sync, reload Jenkins.
#
# Prefer scripts/bootstrap-gitea.sh seed — it creates the PAT automatically.
# Use this script to rotate/override the token manually.
#
# Token sources (first match wins):
#   1) GITEA_TOKEN / GITHUB_TOKEN / GH_TOKEN env
#   2) --token <pat> argument
#
# Username sources:
#   GITEA_USERNAME / GITHUB_USERNAME / GH_USER, else "git"
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/conjur.sh
source "${ROOT_DIR}/scripts/lib/conjur.sh"

CTX="${CONJUR_CONTEXT:-acm}"
TOKEN=""
USERNAME=""
GITEA_URL="${GITEA_URL:-}"

usage() {
  cat <<'EOF'
Usage: scripts/set-conjur-github-pat.sh [--token PAT] [--username USER]

Writes banking/github-ci/{username,token} in Conjur on acm, forces ExternalSecret
github-ci sync, and restarts Jenkins so JCasC picks up the new credential.

Env:
  GITEA_TOKEN / GITHUB_TOKEN   PAT with write access to banking/demo-spring
  GITEA_USERNAME               Gitea login (default: git)
  GITEA_URL                    Base URL for sanity check (default: acm Route)
  CONJUR_CONTEXT               kube context (default: acm)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) TOKEN="${2:-}"; shift 2 ;;
    --username) USERNAME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${TOKEN}" ]]; then
  TOKEN="${GITEA_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
fi
if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: no token. Export GITEA_TOKEN or pass --token" >&2
  exit 1
fi
if [[ "${TOKEN}" == "replace-me" ]]; then
  echo "ERROR: token is still replace-me" >&2
  exit 1
fi

if [[ -z "${USERNAME}" ]]; then
  USERNAME="${GITEA_USERNAME:-${GITHUB_USERNAME:-${GH_USER:-git}}}"
fi

if [[ -z "${GITEA_URL}" ]]; then
  HOST="$(oc --context "${CTX}" -n banking-git get route gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "${HOST}" ]] && GITEA_URL="https://${HOST}"
fi
GITEA_URL="${GITEA_URL:-http://gitea-http.banking-git.svc:3000}"

echo "Using Gitea user=${USERNAME} token_len=${#TOKEN} url=${GITEA_URL} (context=${CTX})"

REPO_SLUG="${GITEA_REPO:-banking/demo-spring}"
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: token ${TOKEN}" \
  "${GITEA_URL}/api/v1/repos/${REPO_SLUG}" || true)"
if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "WARN: Gitea API returned ${HTTP_CODE} for ${REPO_SLUG}; PAT may lack access." >&2
else
  echo "OK: PAT can read ${REPO_SLUG}"
fi

conjur_init
conjur_set_var "banking/github-ci/username" "${USERNAME}"
conjur_set_var "banking/github-ci/token" "${TOKEN}"

echo "Forcing ExternalSecret github-ci sync..."
eso_force_sync "${CTX}" banking-ci github-ci
eso_wait_secret_key "${CTX}" banking-ci github-ci token "${TOKEN}" 180
eso_wait_secret_key "${CTX}" banking-ci github-ci username "${USERNAME}" 30

echo "Restarting Jenkins so JCasC reloads github-ci credential..."
oc --context "${CTX}" -n banking-ci delete pod -l app.kubernetes.io/component=jenkins-controller --wait=false 2>/dev/null \
  || oc --context "${CTX}" -n banking-ci delete pod jenkins-0 --wait=false
oc --context "${CTX}" -n banking-ci rollout status statefulset/jenkins --timeout=300s || true

echo
echo "Done. Jenkins credential id github-ci now mirrors Conjur banking/github-ci/* (Gitea PAT)."
