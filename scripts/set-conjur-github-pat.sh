#!/usr/bin/env bash
# Load a GitHub (or Gitea) PAT into Conjur (banking/github-ci/*), force ESO sync, reload Jenkins.
#
# Token sources (first match wins):
#   1) GITHUB_TOKEN / GH_TOKEN / GITEA_TOKEN env
#   2) --token <pat> argument
#   3) git credential fill for github.com (optional)
#
# Username sources:
#   GITHUB_USERNAME / GH_USER / GITEA_USERNAME, else git credential / "git"
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/conjur.sh
source "${ROOT_DIR}/scripts/lib/conjur.sh"

CTX="${CONJUR_CONTEXT:-acm}"
TOKEN=""
USERNAME=""
GITEA_URL="${GITEA_URL:-}"
GIT_PROVIDER="${GIT_PROVIDER:-auto}" # auto|github|gitea

usage() {
  cat <<'EOF'
Usage: scripts/set-conjur-github-pat.sh [--token PAT] [--username USER]

Writes banking/github-ci/{username,token} in Conjur on acm, forces ExternalSecret
github-ci sync, and restarts Jenkins so JCasC picks up the new credential.

Env:
  GITHUB_TOKEN / GH_TOKEN / GITEA_TOKEN   PAT with push access to the demo repo
  GITHUB_USERNAME / GITEA_USERNAME       Git login
  GIT_PROVIDER                           auto|github|gitea (default auto)
  GITEA_URL                              Gitea base URL when provider=gitea
  CONJUR_CONTEXT                         kube context (default: acm)
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
  TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-${GITEA_TOKEN:-}}}"
fi
if [[ -z "${TOKEN}" ]] && command -v git >/dev/null 2>&1; then
  # Optional: reuse macOS/git credential helper for github.com
  CREDS="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null || true)"
  if [[ -n "${CREDS}" ]]; then
    TOKEN="$(printf '%s\n' "${CREDS}" | awk -F= '/^password=/{print substr($0,10); exit}')"
    if [[ -z "${USERNAME}" ]]; then
      USERNAME="$(printf '%s\n' "${CREDS}" | awk -F= '/^username=/{print substr($0,10); exit}')"
    fi
  fi
fi
if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: no token. Export GITHUB_TOKEN / GITEA_TOKEN or pass --token" >&2
  exit 1
fi
if [[ "${TOKEN}" == "replace-me" ]]; then
  echo "ERROR: token is still replace-me" >&2
  exit 1
fi

if [[ -z "${USERNAME}" ]]; then
  USERNAME="${GITHUB_USERNAME:-${GH_USER:-${GITEA_USERNAME:-}}}"
fi

if [[ "${GIT_PROVIDER}" == "auto" ]]; then
  if [[ "${TOKEN}" == gho_* || "${TOKEN}" == ghp_* || "${TOKEN}" == github_pat_* ]]; then
    GIT_PROVIDER=github
  elif oc --context "${CTX}" -n banking-git get route gitea >/dev/null 2>&1; then
    GIT_PROVIDER=gitea
  else
    GIT_PROVIDER=github
  fi
fi

if [[ "${GIT_PROVIDER}" == "gitea" ]]; then
  if [[ -z "${GITEA_URL}" ]]; then
    HOST="$(oc --context "${CTX}" -n banking-git get route gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -n "${HOST}" ]] && GITEA_URL="https://${HOST}"
  fi
  GITEA_URL="${GITEA_URL:-http://gitea-http.banking-git.svc:3000}"
  USERNAME="${USERNAME:-git}"
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
else
  # Prefer explicit login name over numeric credential-helper ids
  if [[ -z "${USERNAME}" || "${USERNAME}" =~ ^[0-9]+$ ]]; then
    USERNAME="${GITHUB_USERNAME:-${GH_USER:-panchoraposo}}"
  fi
  echo "Using GitHub user=${USERNAME} token_len=${#TOKEN} (context=${CTX})"
  REPO_SLUG="${GITHUB_REPO:-panchoraposo/demo-spring}"
  HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO_SLUG}" || true)"
  if [[ "${HTTP_CODE}" != "200" ]]; then
    echo "WARN: GitHub API returned ${HTTP_CODE} for ${REPO_SLUG}; PAT may lack access." >&2
  else
    echo "OK: PAT can read ${REPO_SLUG}"
  fi
  # Push permission probe (contents:write) via collaborative permission endpoint
  PERM="$(curl -sS -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO_SLUG}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("permissions") or {}).get("push"))' 2>/dev/null || true)"
  if [[ "${PERM}" == "True" || "${PERM}" == "true" ]]; then
    echo "OK: PAT has push on ${REPO_SLUG}"
  else
    echo "WARN: could not confirm push permission (permissions.push=${PERM:-unknown})" >&2
  fi
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
echo "Done. Jenkins credential id github-ci now mirrors Conjur banking/github-ci/* (${GIT_PROVIDER} PAT)."
