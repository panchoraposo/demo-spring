#!/usr/bin/env bash
# Register the CI cosign public key as an RHACS Signature Integration so the
# portal can show Verified for images signed by Jenkins (sign-and-attest.sh).
set -euo pipefail

ACM_CONTEXT="${ACM_CONTEXT:-acm}"
CI_NS="${CI_NS:-banking-ci}"
ACS_NS="${ACS_NS:-stackrox}"
NAME="${ACS_SIGNATURE_INTEGRATION_NAME:-Banking Demo Cosign}"
KEY_NAME="${ACS_COSIGN_KEY_NAME:-banking-ci cosign.pub}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need oc; need curl; need python3

ACS_HOST="$(oc --context "${ACM_CONTEXT}" -n "${ACS_NS}" get route central -o jsonpath='{.spec.host}')"
ADMIN_PASS="$(oc --context "${ACM_CONTEXT}" -n "${ACS_NS}" get secret central-htpasswd -o jsonpath='{.data.password}' | base64 -d)"
PUB="$(oc --context "${ACM_CONTEXT}" -n "${CI_NS}" get secret cosign-signing-key -o jsonpath='{.data.cosign\.pub}' | base64 -d)"
[[ -n "${PUB}" ]] || { echo "ERROR: cosign.pub missing in secret/${CI_NS}/cosign-signing-key" >&2; exit 1; }

AUTH=(-u "admin:${ADMIN_PASS}")
BASE="https://${ACS_HOST}/v1/signatureintegrations"

EXISTING_ID="$(curl -sk "${AUTH[@]}" "${BASE}" | python3 -c "
import sys, json
name = '''${NAME}'''
for i in json.load(sys.stdin).get('integrations', []):
    if i.get('name') == name:
        print(i.get('id', ''))
        break
")"

BODY="$(PUB="${PUB}" KEY_NAME="${KEY_NAME}" NAME="${NAME}" python3 - <<'PY'
import json, os
print(json.dumps({
    "name": os.environ["NAME"],
    "cosign": {
        "publicKeys": [{
            "name": os.environ["KEY_NAME"],
            "publicKeyPemEnc": os.environ["PUB"].rstrip() + "\n",
        }]
    },
}))
PY
)"

if [[ -n "${EXISTING_ID}" ]]; then
  echo "==> updating Signature Integration ${NAME} (${EXISTING_ID})"
  BODY="$(python3 -c "import json,sys; b=json.loads(sys.argv[1]); b['id']=sys.argv[2]; print(json.dumps(b))" "${BODY}" "${EXISTING_ID}")"
  curl -sk "${AUTH[@]}" -X PUT -H 'Content-Type: application/json' \
    "${BASE}/${EXISTING_ID}" -d "${BODY}" | python3 -c "
import sys,json
i=json.load(sys.stdin)
print('OK', i.get('name'), i.get('id'))
"
else
  echo "==> creating Signature Integration ${NAME}"
  curl -sk "${AUTH[@]}" -X POST -H 'Content-Type: application/json' \
    "${BASE}" -d "${BODY}" | python3 -c "
import sys,json
i=json.load(sys.stdin)
print('OK', i.get('name'), i.get('id'))
"
fi

echo
echo "In ACS: Platform Configuration → Integrations → Signature → ${NAME}"
echo "Re-scan an image (or wait for the next Sensor pull) to refresh the Verified badge."
