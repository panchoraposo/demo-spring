#!/usr/bin/env bash
# Ensure TPA vulnerability/advisory importers are enabled after install.
# createImporters may seed defaults as disabled; this makes enablement idempotent via API.
set -euo pipefail

CTX="${CTX:-acm}"
TPA_NS="${TPA_NS:-trusted-profile-analyzer}"
CI_NS="${CI_NS:-banking-ci}"
# Match demo CR defaults (osv/cve for Maven; csaf for RHEL RPMs in container SBOMs).
IMPORTERS="${TPA_IMPORTERS:-osv-github cve redhat-csaf}"

echo "==> Waiting for TPA server route in ${TPA_NS}"
TPA_HOST=""
for i in $(seq 1 60); do
  TPA_HOST="$(oc --context "${CTX}" -n "${TPA_NS}" get route -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.host}{"\t"}{.spec.to.name}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' '$3 != "rhda-backend" && $2 != "" { print $2; exit }' || true)"
  if [[ -n "${TPA_HOST}" ]]; then
    code="$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 "https://${TPA_HOST}/api/v3/sbom" || true)"
    echo "[$i] host=${TPA_HOST} HTTP=${code}"
    # 401/403 means API is up but unauthenticated; 200 is also fine.
    if [[ "${code}" =~ ^(200|401|403)$ ]]; then
      break
    fi
  else
    echo "[$i] host=none"
  fi
  sleep 15
  if [[ "${i}" -eq 60 ]]; then
    echo "ERROR: TPA server route/API not ready in ${TPA_NS}" >&2
    exit 1
  fi
done

TPA_URL="https://${TPA_HOST}"
echo "TPA URL: ${TPA_URL}"

echo "==> Resolve OIDC cli client secret"
CLIENT_SECRET="${TPA_OIDC_CLIENT_SECRET:-}"
if [[ -z "${CLIENT_SECRET}" ]]; then
  CLIENT_SECRET="$(oc --context "${CTX}" -n "${CI_NS}" get secret tpa-oidc-cli \
    -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d || true)"
fi
if [[ -z "${CLIENT_SECRET}" ]]; then
  CLIENT_SECRET="$(oc --context "${CTX}" -n "${TPA_NS}" get secret oidc-cli \
    -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d || true)"
fi
if [[ -z "${CLIENT_SECRET}" ]]; then
  echo "ERROR: missing TPA OIDC cli client secret (set TPA_OIDC_CLIENT_SECRET or sync ESO)." >&2
  exit 1
fi

# Issuer: shared banking-idp SSO / trustify realm (same convention as CI).
SSO_HOST="$(oc --context "${CTX}" -n banking-idp get route sso -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -z "${SSO_HOST}" ]]; then
  if [[ "${TPA_HOST}" == server.* ]]; then
    SSO_HOST="sso.${TPA_HOST#server.}"
  else
    echo "ERROR: cannot derive SSO host for trustify realm" >&2
    exit 1
  fi
fi
TOKEN_URL="https://${SSO_HOST}/realms/trustify/protocol/openid-connect/token"

echo "==> Obtain TPA OIDC token (client_credentials)"
TOKEN_HTTP="$(curl -sk -o /tmp/tpa-oidc.json -w '%{http_code}' -X POST "${TOKEN_URL}" \
  -d 'grant_type=client_credentials' \
  -d 'client_id=cli' \
  -d "client_secret=${CLIENT_SECRET}" \
  -d 'scope=create:document read:document' || true)"
TOKEN="$(sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /tmp/tpa-oidc.json | head -1 || true)"
if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: failed to get TPA token (HTTP ${TOKEN_HTTP})" >&2
  head -c 300 /tmp/tpa-oidc.json 2>/dev/null || true
  echo >&2
  exit 1
fi

enable_importer() {
  local name="$1"
  local code
  code="$(curl -sk -o /tmp/tpa-importer-enable.out -w '%{http_code}' -X PUT \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    --data 'true' \
    "${TPA_URL}/api/v3/importer/${name}/enabled" || true)"
  if [[ "${code}" != "200" && "${code}" != "201" && "${code}" != "204" ]]; then
    echo "WARN: enable ${name} HTTP=${code} $(head -c 200 /tmp/tpa-importer-enable.out 2>/dev/null || true)" >&2
    return 1
  fi
  # Nudge a run (best-effort; disabled→enabled already schedules work).
  curl -sk -o /dev/null -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    --data 'true' \
    "${TPA_URL}/api/v3/importer/${name}/force" || true
  echo "enabled ${name}"
}

echo "==> Enable importers: ${IMPORTERS}"
failed=0
for name in ${IMPORTERS}; do
  enable_importer "${name}" || failed=$((failed + 1))
done

echo "==> Importer status"
curl -sk -H "Authorization: Bearer ${TOKEN}" "${TPA_URL}/api/v3/importer" \
  | python3 -c '
import json, sys
for i in json.load(sys.stdin):
    cfg = list(i["configuration"].values())[0]
    print("%s: disabled=%s state=%s progress=%s" % (
        i["name"], cfg.get("disabled"), i.get("state"), i.get("progress")))
' 2>/dev/null || curl -sk -H "Authorization: Bearer ${TOKEN}" "${TPA_URL}/api/v3/importer" | head -c 800

if [[ "${failed}" -gt 0 ]]; then
  echo "ERROR: failed to enable ${failed} importer(s)" >&2
  exit 1
fi
echo "TPA importers ready (first advisory sync may still be in progress)."
