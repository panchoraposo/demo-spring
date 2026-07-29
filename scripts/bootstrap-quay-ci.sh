#!/usr/bin/env bash
# Wait for Quay on acm, create org/repos/robot via API, store quay-ci + cosign key for Jenkins.
set -euo pipefail

CTX="${CTX:-acm}"
QUAY_NS="${QUAY_NS:-quay-enterprise}"
QUAY_NAME="${QUAY_NAME:-banking-quay}"
ORG="${QUAY_ORG:-banking}"
ROBOT="${QUAY_ROBOT:-ci}"
CI_NS="${CI_NS:-banking-ci}"
SUPERUSER="${QUAY_SUPERUSER:-quayadmin}"
SUPERPASS="${QUAY_SUPERPASS:-QuayAdminChangeMe1!}"
EMAIL="${QUAY_EMAIL:-quayadmin@banking-demo.local}"

echo "==> Waiting for QuayRegistry ${QUAY_NS}/${QUAY_NAME} to become Available"
for i in $(seq 1 90); do
  blocked="$(oc --context "${CTX}" -n "${QUAY_NS}" get quayregistry "${QUAY_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="RolloutBlocked")].status}' 2>/dev/null || true)"
  avail="$(oc --context "${CTX}" -n "${QUAY_NS}" get quayregistry "${QUAY_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  host="$(oc --context "${CTX}" -n "${QUAY_NS}" get route -l quay-component=quay \
    -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
  echo "[$i] RolloutBlocked=${blocked:-?} Available=${avail:-?} host=${host:-none}"
  if [[ "${avail}" == "True" && -n "${host}" ]]; then
    QUAY_HOST="${host}"
    break
  fi
  sleep 20
  if [[ "${i}" -eq 90 ]]; then
    echo "ERROR: Quay not Ready. Check ODF/MCG ObjectBucketClaim support." >&2
    oc --context "${CTX}" -n "${QUAY_NS}" get quayregistry "${QUAY_NAME}" -o yaml | tail -40 >&2 || true
    exit 1
  fi
done

QUAY_URL="https://${QUAY_HOST}"
echo "Quay URL: ${QUAY_URL}"

# Create / login superuser (Quay user initialize API)
echo "==> Ensuring superuser ${SUPERUSER}"
curl -sk -X POST "${QUAY_URL}/api/v1/user/initialize" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"${SUPERUSER}\",\"password\":\"${SUPERPASS}\",\"email\":\"${EMAIL}\",\"access_token\":true}" \
  >/tmp/quay-init.json 2>/dev/null || true

TOKEN="$(python3 - <<'PY'
import json,sys
try:
  print(json.load(open("/tmp/quay-init.json")).get("access_token") or json.load(open("/tmp/quay-init.json")).get("token") or "")
except Exception:
  print("")
PY
)"

if [[ -z "${TOKEN}" ]]; then
  echo "Initialize may have already run; obtaining token via auth login"
  # Fallback: create OAuth app is heavy — use basic auth against API where supported
  # Quay supports username/password for some endpoints via Bearer from /api/v1/signin in older versions.
  # Prefer existing config.secret password if present.
  TOKEN="$(curl -sk -u "${SUPERUSER}:${SUPERPASS}" "${QUAY_URL}/api/v1/user" \
    -H 'Accept: application/json' >/dev/null && echo "USE_BASIC")"
fi

auth_hdr() {
  if [[ "${TOKEN}" == "USE_BASIC" || -z "${TOKEN}" ]]; then
    echo -n "-u ${SUPERUSER}:${SUPERPASS}"
  else
    echo -n "-H Authorization: Bearer ${TOKEN}"
  fi
}

echo "==> Create organization ${ORG}"
# shellcheck disable=SC2046
curl -sk $(auth_hdr) -X POST "${QUAY_URL}/api/v1/organization/" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"${ORG}\",\"email\":\"${EMAIL}\"}" >/dev/null || true

for repo in banking-service api-gateway; do
  echo "==> Create repository ${ORG}/${repo}"
  # shellcheck disable=SC2046
  curl -sk $(auth_hdr) -X POST "${QUAY_URL}/api/v1/repository" \
    -H 'Content-Type: application/json' \
    -d "{\"namespace\":\"${ORG}\",\"repository\":\"${repo}\",\"description\":\"banking demo\",\"visibility\":\"private\",\"repo_kind\":\"image\"}" \
    >/dev/null || true
done

echo "==> Create robot ${ORG}+${ROBOT}"
# shellcheck disable=SC2046
curl -sk $(auth_hdr) -X PUT "${QUAY_URL}/api/v1/organization/${ORG}/robots/${ROBOT}" \
  -H 'Content-Type: application/json' \
  -d '{"description":"Jenkins CI push"}' >/tmp/quay-robot.json || true

ROBOT_TOKEN="$(python3 - <<'PY'
import json
try:
  d=json.load(open("/tmp/quay-robot.json"))
  print(d.get("token") or d.get("name") and "" or "")
except Exception:
  print("")
PY
)"
ROBOT_NAME="${ORG}+${ROBOT}"

if [[ -z "${ROBOT_TOKEN}" ]]; then
  # fetch existing robot token (may need regenerate)
  # shellcheck disable=SC2046
  curl -sk $(auth_hdr) -X POST "${QUAY_URL}/api/v1/organization/${ORG}/robots/${ROBOT}/regenerate" \
    >/tmp/quay-robot.json || true
  ROBOT_TOKEN="$(python3 -c 'import json;print(json.load(open("/tmp/quay-robot.json")).get("token",""))' 2>/dev/null || true)"
fi

if [[ -z "${ROBOT_TOKEN}" ]]; then
  echo "ERROR: could not obtain robot token; create manually in Quay UI and set secret quay-ci" >&2
  exit 1
fi

# Grant write on repos
for repo in banking-service api-gateway; do
  # shellcheck disable=SC2046
  curl -sk $(auth_hdr) -X PUT \
    "${QUAY_URL}/api/v1/repository/${ORG}/${repo}/permissions/team/${ROBOT}" \
    -H 'Content-Type: application/json' \
    -d '{"role":"admin"}' >/dev/null 2>&1 || true
  # shellcheck disable=SC2046
  curl -sk $(auth_hdr) -X PUT \
    "${QUAY_URL}/api/v1/repository/${ORG}/${repo}/permissions/user/${ROBOT_NAME}" \
    -H 'Content-Type: application/json' \
    -d '{"role":"write"}' >/dev/null 2>&1 || true
done

echo "==> Store Secret ${CI_NS}/quay-ci"
oc --context "${CTX}" -n "${CI_NS}" create secret generic quay-ci \
  --from-literal=username="${ROBOT_NAME}" \
  --from-literal=password="${ROBOT_TOKEN}" \
  --dry-run=client -o yaml | oc --context "${CTX}" apply -f -

if ! oc --context "${CTX}" -n "${CI_NS}" get secret cosign-signing-key >/dev/null 2>&1; then
  echo "==> Generate cosign key pair for CI signing"
  TOOLS="$(mktemp -d)"
  if [[ ! -x "${TOOLS}/cosign" ]]; then
    curl -fsSL "https://github.com/sigstore/cosign/releases/download/v2.4.3/cosign-linux-amd64" \
      -o "${TOOLS}/cosign"
    chmod +x "${TOOLS}/cosign"
  fi
  COSIGN_PASSWORD="" "${TOOLS}/cosign" generate-key-pair -d "${TOOLS}" >/dev/null
  # cosign writes cosign.key / cosign.pub in cwd
  (cd "${TOOLS}" && COSIGN_PASSWORD="" "${TOOLS}/cosign" generate-key-pair)
  oc --context "${CTX}" -n "${CI_NS}" create secret generic cosign-signing-key \
    --from-file=cosign.key="${TOOLS}/cosign.key" \
    --from-file=cosign.pub="${TOOLS}/cosign.pub" \
    --dry-run=client -o yaml | oc --context "${CTX}" apply -f -
  rm -rf "${TOOLS}"
else
  echo "Secret cosign-signing-key already exists — leaving it"
fi

echo "==> Restart Jenkins to load quay-ci / cosign credentials"
oc --context "${CTX}" -n "${CI_NS}" delete pod jenkins-0 --wait=false || true

echo
echo "Quay CI ready:"
echo "  host  : ${QUAY_HOST}"
echo "  robot : ${ROBOT_NAME}"
echo "  secrets: ${CI_NS}/quay-ci , ${CI_NS}/cosign-signing-key"
