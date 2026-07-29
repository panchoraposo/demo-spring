#!/usr/bin/env bash
# Manual Vault init/unseal helper for cluster east (demo).
# Prefer the GitOps Job vault-bootstrap; use this if you need to recover locally.
set -euo pipefail

NS="${NS:-banking-vault}"
ROOT_SECRET_NAME="${ROOT_SECRET_NAME:-vault-root-token}"
VAULT_POD="$(oc get pod -n "${NS}" -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')"

if [[ -z "${VAULT_POD}" ]]; then
  echo "No Vault pod found in ${NS}" >&2
  exit 1
fi

if ! oc get secret "${ROOT_SECRET_NAME}" -n "${NS}" >/dev/null 2>&1; then
  echo "Initializing Vault..."
  INIT_JSON="$(oc exec -n "${NS}" "${VAULT_POD}" -- vault operator init -key-shares=1 -key-threshold=1 -format=json)"
  UNSEAL_KEY="$(printf '%s' "${INIT_JSON}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["unseal_keys_b64"][0])')"
  ROOT_TOKEN="$(printf '%s' "${INIT_JSON}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["root_token"])')"
  oc create secret generic "${ROOT_SECRET_NAME}" -n "${NS}" \
    --from-literal=root-token="${ROOT_TOKEN}" \
    --from-literal=unseal-key="${UNSEAL_KEY}"
  echo "DEMO ONLY: wrote ${NS}/${ROOT_SECRET_NAME}"
fi

UNSEAL_KEY="$(oc get secret "${ROOT_SECRET_NAME}" -n "${NS}" -o jsonpath='{.data.unseal-key}' | base64 -d)"
if oc exec -n "${NS}" "${VAULT_POD}" -- vault status -format=json 2>/dev/null \
  | python3 -c 'import sys,json; raise SystemExit(0 if json.load(sys.stdin).get("sealed") else 1)'; then
  echo "Unsealing..."
  oc exec -n "${NS}" "${VAULT_POD}" -- vault operator unseal "${UNSEAL_KEY}" >/dev/null
fi

echo "Vault is unsealed. Re-run / sync the vault-config Application to apply policies and seed data."
