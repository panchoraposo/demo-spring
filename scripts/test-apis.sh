#!/usr/bin/env bash
# Smoke-test banking APIs via api-gateway on one or more spoke clusters.
#
# Usage:
#   ./scripts/test-apis.sh              # east west (default)
#   CONTEXTS=east ./scripts/test-apis.sh
#   WRITE=1 ./scripts/test-apis.sh      # also create customer/account/transfer
#
# Requires: oc, curl, jq
set -euo pipefail

CONTEXTS="${CONTEXTS:-east west}"
WRITE="${WRITE:-0}"
USER="${BANKING_USER:-teller}"
PASS="${BANKING_PASSWORD:-teller-change-me}"
CLIENT_ID="${BANKING_CLIENT_ID:-banking-cli}"

need() { command -v "$1" >/dev/null || { echo "missing dependency: $1" >&2; exit 1; }; }
need oc; need curl; need jq

json_pp() { jq -C . 2>/dev/null || jq .; }

get_token() {
  local keycloak_url="$1"
  curl -sk -X POST "${keycloak_url}/realms/banking/protocol/openid-connect/token" \
    -d "client_id=${CLIENT_ID}" \
    -d "username=${USER}" \
    -d "password=${PASS}" \
    -d "grant_type=password" | jq -r '.access_token // empty'
}

api() {
  local method="$1" url="$2" token="$3"
  local body="${4:-}"
  local tmp code
  tmp="$(mktemp)"
  if [[ -n "${body}" ]]; then
    code="$(curl -sk -o "${tmp}" -w '%{http_code}' -X "${method}" "${url}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "${body}")"
  else
    code="$(curl -sk -o "${tmp}" -w '%{http_code}' -X "${method}" "${url}" \
      -H "Authorization: Bearer ${token}")"
  fi
  printf '%s' "${code}|${tmp}"
}

expect_2xx() {
  local label="$1" code="$2" body_file="$3"
  if [[ "${code}" =~ ^2 ]]; then
    echo "  OK  ${label} (${code})"
    [[ "${VERBOSE:-0}" == "1" ]] && json_pp <"${body_file}"
  else
    echo "  FAIL ${label} (${code})" >&2
    json_pp <"${body_file}" >&2 || cat "${body_file}" >&2
    return 1
  fi
}

test_cluster() {
  local ctx="$1"
  echo "==> ${ctx}"

  local gateway_host gateway_url keycloak_url token
  gateway_host="$(oc --context "${ctx}" -n banking-apps get route api-gateway -o jsonpath='{.spec.host}')"
  gateway_url="https://${gateway_host}"
  # Single IdP for the demo lives on the hub (acm): Route banking-idp/sso
  keycloak_url="https://$(oc --context "${HUB_CONTEXT:-acm}" -n banking-idp get route sso -o jsonpath='{.spec.host}')"
  echo "  gateway:  ${gateway_url}"
  echo "  keycloak: ${keycloak_url}"

  token="$(get_token "${keycloak_url}")"
  if [[ -z "${token}" ]]; then
    echo "  FAIL could not obtain JWT (client=${CLIENT_ID} user=${USER})" >&2
    return 1
  fi
  echo "  OK  JWT obtained"

  local out code body
  out="$(api GET "${gateway_url}/api/v1/customers" "${token}")"
  code="${out%%|*}"; body="${out#*|}"
  expect_2xx "GET /api/v1/customers" "${code}" "${body}"
  rm -f "${body}"

  out="$(api GET "${gateway_url}/api/v1/accounts" "${token}")"
  code="${out%%|*}"; body="${out#*|}"
  expect_2xx "GET /api/v1/accounts" "${code}" "${body}"
  rm -f "${body}"

  out="$(api GET "${gateway_url}/api/v1/transactions" "${token}")"
  code="${out%%|*}"; body="${out#*|}"
  expect_2xx "GET /api/v1/transactions" "${code}" "${body}"
  rm -f "${body}"

  if [[ "${WRITE}" != "1" ]]; then
    echo "  (set WRITE=1 to exercise POST customer/account/transfer)"
    return 0
  fi

  local nid email customer_id account_a account_b
  nid="NID-$(date +%s)-${ctx}"
  email="demo-$(date +%s)-${ctx}@bank.demo"

  out="$(api POST "${gateway_url}/api/v1/customers" "${token}" \
    "{\"firstName\":\"Ada\",\"lastName\":\"Lovelace\",\"email\":\"${email}\",\"nationalId\":\"${nid}\"}")"
  code="${out%%|*}"; body="${out#*|}"
  expect_2xx "POST /api/v1/customers" "${code}" "${body}"
  customer_id="$(jq -r '.id // empty' "${body}")"
  rm -f "${body}"
  [[ -n "${customer_id}" ]] || { echo "  FAIL missing customer id" >&2; return 1; }
  echo "  customerId=${customer_id}"

  out="$(api POST "${gateway_url}/api/v1/accounts" "${token}" \
    "{\"customerId\":${customer_id},\"type\":\"CHECKING\",\"currency\":\"USD\",\"initialDeposit\":1000.00}")"
  code="${out%%|*}"; body="${out#*|}"
  expect_2xx "POST /api/v1/accounts (CHECKING)" "${code}" "${body}"
  account_a="$(jq -r '.id // empty' "${body}")"
  rm -f "${body}"

  out="$(api POST "${gateway_url}/api/v1/accounts" "${token}" \
    "{\"customerId\":${customer_id},\"type\":\"SAVINGS\",\"currency\":\"USD\",\"initialDeposit\":250.00}")"
  code="${out%%|*}"; body="${out#*|}"
  expect_2xx "POST /api/v1/accounts (SAVINGS)" "${code}" "${body}"
  account_b="$(jq -r '.id // empty' "${body}")"
  rm -f "${body}"
  echo "  accountA=${account_a} accountB=${account_b}"

  out="$(api GET "${gateway_url}/api/v1/accounts/${account_a}/balance" "${token}")"
  code="${out%%|*}"; body="${out#*|}"
  expect_2xx "GET /api/v1/accounts/${account_a}/balance" "${code}" "${body}"
  [[ "${VERBOSE:-0}" == "1" ]] || json_pp <"${body}"
  rm -f "${body}"

  out="$(api POST "${gateway_url}/api/v1/transfers" "${token}" \
    "{\"fromAccountId\":${account_a},\"toAccountId\":${account_b},\"amount\":125.50,\"description\":\"demo transfer\"}")"
  code="${out%%|*}"; body="${out#*|}"
  expect_2xx "POST /api/v1/transfers" "${code}" "${body}"
  rm -f "${body}"

  out="$(api GET "${gateway_url}/api/v1/transactions?accountId=${account_a}" "${token}")"
  code="${out%%|*}"; body="${out#*|}"
  expect_2xx "GET /api/v1/transactions?accountId=${account_a}" "${code}" "${body}"
  [[ "${VERBOSE:-0}" == "1" ]] || json_pp <"${body}"
  rm -f "${body}"
}

failed=0
for ctx in ${CONTEXTS}; do
  test_cluster "${ctx}" || failed=1
  echo
done

if [[ "${failed}" -ne 0 ]]; then
  echo "One or more clusters failed." >&2
  exit 1
fi
echo "All API checks passed."
