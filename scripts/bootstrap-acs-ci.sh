#!/usr/bin/env bash
# Create an RHACS API token for Jenkins image checks and store it in banking-ci.
#
# Prerequisites: Central Ready on acm.
# Optional: ROX_ADMIN_PASSWORD (defaults to central-htpasswd secret).
set -euo pipefail

ACM_CONTEXT="${ACM_CONTEXT:-acm}"
STACKROX_NS="${STACKROX_NS:-stackrox}"
CI_NS="${CI_NS:-banking-ci}"
TOKEN_NAME="${TOKEN_NAME:-jenkins-ci}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need oc; need curl; need jq

echo "==> waiting for Central"
oc --context "${ACM_CONTEXT}" -n "${STACKROX_NS}" wait --for=condition=Deployed centrals.platform.stackrox.io/stackrox-central-services --timeout=600s 2>/dev/null \
  || oc --context "${ACM_CONTEXT}" -n "${STACKROX_NS}" rollout status deploy/central --timeout=600s

HOST="$(oc --context "${ACM_CONTEXT}" -n "${STACKROX_NS}" get route central -o jsonpath='{.spec.host}' 2>/dev/null \
  || oc --context "${ACM_CONTEXT}" -n "${STACKROX_NS}" get route -l app.kubernetes.io/name=central -o jsonpath='{.items[0].spec.host}')"
CENTRAL="https://${HOST}"
echo "Central: ${CENTRAL}"

if [[ -z "${ROX_ADMIN_PASSWORD:-}" ]]; then
  ROX_ADMIN_PASSWORD="$(oc --context "${ACM_CONTEXT}" -n "${STACKROX_NS}" get secret central-htpasswd \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
fi
[[ -n "${ROX_ADMIN_PASSWORD:-}" ]] || {
  echo "ERROR: set ROX_ADMIN_PASSWORD or ensure secret central-htpasswd exists" >&2
  exit 1
}

# Prefer roxctl if available; else Central API.
TOKEN=""
if command -v roxctl >/dev/null 2>&1; then
  echo "==> creating API token with roxctl"
  TOKEN="$(ROX_CENTRAL_ADDRESS="${HOST}:443" ROX_API_TOKEN="" \
    roxctl central whoami --insecure-skip-tls-verify -p "${ROX_ADMIN_PASSWORD}" >/dev/null 2>&1 || true)"
  TOKEN="$(ROX_CENTRAL_ADDRESS="${HOST}:443" \
    roxctl central token create --name "${TOKEN_NAME}" --role Continuous Integration \
      --insecure-skip-tls-verify -p "${ROX_ADMIN_PASSWORD}" 2>/dev/null | awk '/^eyJ/{print; exit}')" || true
fi

if [[ -z "${TOKEN}" ]]; then
  echo "==> creating API token via Central REST API"
  # Login for short-lived token then create long-lived API token.
  TMP="$(mktemp)"
  curl -sk -X POST "${CENTRAL}/v1/apitokens/generate" \
    -u "admin:${ROX_ADMIN_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${TOKEN_NAME}\",\"roles\":[\"Continuous Integration\"]}" \
    -o "${TMP}" || true
  TOKEN="$(jq -r '.token // empty' "${TMP}")"
  rm -f "${TMP}"
fi

[[ -n "${TOKEN}" ]] || {
  echo "ERROR: could not create ACS API token (check Central auth / roles)" >&2
  exit 1
}

echo "==> writing Secret ${CI_NS}/acs-ci"
oc --context "${ACM_CONTEXT}" -n "${CI_NS}" create secret generic acs-ci \
  --from-literal=central-url="${CENTRAL}" \
  --from-literal=api-token="${TOKEN}" \
  --dry-run=client -o yaml | oc --context "${ACM_CONTEXT}" apply -f -

echo
echo "Done. Jenkins credential id 'acs-ci' (string) / env ACS_API_TOKEN + ACS_CENTRAL_URL."
echo "Test: ROX_API_TOKEN=… ROX_CENTRAL_ADDRESS=${HOST}:443 roxctl image check --image=<quay>/banking/banking-service:latest"
