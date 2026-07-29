#!/usr/bin/env bash
# Shared helpers to authenticate to Conjur on acm and set/get variables.
# shellcheck shell=bash

conjur_init() {
  CONJUR_CONTEXT="${CONJUR_CONTEXT:-acm}"
  CONJUR_NS="${CONJUR_NS:-banking-conjur}"
  CONJUR_ACCOUNT="${CONJUR_ACCOUNT:-banking}"
  CONJUR_RELEASE="${CONJUR_RELEASE:-conjur-oss}"

  CONJUR_URL="$(oc --context "${CONJUR_CONTEXT}" -n "${CONJUR_NS}" get route conjur \
    -o jsonpath='https://{.spec.host}' 2>/dev/null || true)"
  if [[ -z "${CONJUR_URL}" ]]; then
    CONJUR_URL="https://conjur-oss.${CONJUR_NS}.svc"
  fi

  CONJUR_CA="$(mktemp)"
  oc --context "${CONJUR_CONTEXT}" -n "${CONJUR_NS}" get secret \
    "${CONJUR_RELEASE}-conjur-ssl-ca-cert" -o jsonpath='{.data.tls\.crt}' \
    | base64 -d > "${CONJUR_CA}"

  local pod
  pod="$(oc --context "${CONJUR_CONTEXT}" -n "${CONJUR_NS}" get pod \
    -l app=conjur-oss --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${pod}" ]]; then
    pod="$(oc --context "${CONJUR_CONTEXT}" -n "${CONJUR_NS}" get pod \
      -l app.kubernetes.io/name=conjur-oss --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  fi
  [[ -n "${pod}" ]] || { echo "ERROR: Conjur pod not found on ${CONJUR_CONTEXT}" >&2; return 1; }

  CONJUR_ADMIN_API_KEY="$(oc --context "${CONJUR_CONTEXT}" -n "${CONJUR_NS}" exec "${pod}" -c conjur-oss -- \
    conjurctl role retrieve-key "${CONJUR_ACCOUNT}:user:admin" 2>/dev/null | tr -d '\r\n')"
  [[ -n "${CONJUR_ADMIN_API_KEY}" ]] || { echo "ERROR: failed to retrieve Conjur admin API key" >&2; return 1; }

  CONJUR_TOKEN="$(conjur_auth_token admin "${CONJUR_ADMIN_API_KEY}")"
  [[ -n "${CONJUR_TOKEN}" ]] || { echo "ERROR: Conjur authenticate failed" >&2; return 1; }
}

conjur_auth_token() {
  local login="$1" api_key="$2" enc_login
  enc_login="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "${login}")"
  curl -sf --cacert "${CONJUR_CA}" -X POST \
    --data-binary "${api_key}" \
    "${CONJUR_URL}/authn/${CONJUR_ACCOUNT}/${enc_login}/authenticate" \
    | base64 | tr -d '\n'
}

conjur_set_var() {
  local id="$1" value="$2" enc_id
  enc_id="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "${id}")"
  # Re-auth each write — tokens can be short-lived
  CONJUR_TOKEN="$(conjur_auth_token admin "${CONJUR_ADMIN_API_KEY}")"
  curl -sf --cacert "${CONJUR_CA}" -X POST \
    -H "Authorization: Token token=\"${CONJUR_TOKEN}\"" \
    -H "Content-Type: text/plain" \
    --data-binary "${value}" \
    "${CONJUR_URL}/secrets/${CONJUR_ACCOUNT}/variable/${enc_id}" >/dev/null
  echo "Conjur set ${id}"
}

conjur_get_var() {
  local id="$1" enc_id
  enc_id="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "${id}")"
  CONJUR_TOKEN="$(conjur_auth_token admin "${CONJUR_ADMIN_API_KEY}")"
  curl -sf --cacert "${CONJUR_CA}" \
    -H "Authorization: Token token=\"${CONJUR_TOKEN}\"" \
    "${CONJUR_URL}/secrets/${CONJUR_ACCOUNT}/variable/${enc_id}"
}

eso_force_sync() {
  local ctx="$1" ns="$2" name="$3"
  # Bump an annotation so the ExternalSecret reconciles immediately.
  oc --context "${ctx}" -n "${ns}" annotate externalsecret "${name}" \
    force-sync="$(date +%s)" --overwrite >/dev/null
  # Also shorten wait by requesting a refresh via annotation used by ESO
  oc --context "${ctx}" -n "${ns}" annotate externalsecret "${name}" \
    reconcile.external-secrets.io/requested-at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite >/dev/null 2>&1 || true
}

eso_wait_secret_key() {
  local ctx="$1" ns="$2" secret="$3" key="$4" expected="$5" timeout="${6:-120}"
  local i val
  for i in $(seq 1 "${timeout}"); do
    val="$(oc --context "${ctx}" -n "${ns}" get secret "${secret}" -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d || true)"
    if [[ "${val}" == "${expected}" ]]; then
      echo "OK: ${ctx}/${ns}/${secret}.${key} == expected"
      return 0
    fi
    sleep 1
  done
  echo "ERROR: timed out waiting for ${ctx}/${ns}/${secret}.${key}" >&2
  echo "  last value (masked): ${val:0:4}… (len=${#val})" >&2
  return 1
}
