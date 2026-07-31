#!/usr/bin/env bash
# Bootstrap Nexus on acm:
#   - wait for ready
#   - create maven-central + maven-redhat proxies and maven-public group
#   - optionally seed Conjur banking/nexus/* and banking-ci/nexus-ci Secret
set -euo pipefail

ACM_CONTEXT="${ACM_CONTEXT:-acm}"
NEXUS_NS="${NEXUS_NS:-nexus}"
CI_NS="${CI_NS:-banking-ci}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need oc; need curl; need jq

echo "==> waiting for Nexus Deployment"
oc --context "${ACM_CONTEXT}" -n "${NEXUS_NS}" rollout status deploy/nexus --timeout=600s

HOST="$(oc --context "${ACM_CONTEXT}" -n "${NEXUS_NS}" get route nexus -o jsonpath='{.spec.host}')"
BASE="https://${HOST}"
echo "Nexus UI: ${BASE}"

# Initial admin password written once into the PVC.
echo "==> reading initial admin password from PVC"
ADMIN_PASS="$(oc --context "${ACM_CONTEXT}" -n "${NEXUS_NS}" exec deploy/nexus -- \
  cat /nexus-data/admin.password 2>/dev/null || true)"
if [[ -z "${ADMIN_PASS}" ]]; then
  # Already changed — fall back to Conjur/demo default if present.
  ADMIN_PASS="${NEXUS_ADMIN_PASSWORD:-}"
fi
[[ -n "${ADMIN_PASS}" ]] || {
  echo "ERROR: cannot read admin password. Set NEXUS_ADMIN_PASSWORD or check /nexus-data/admin.password" >&2
  exit 1
}

auth=(-u "admin:${ADMIN_PASS}")

# Change default password on first login if still the generated one.
if oc --context "${ACM_CONTEXT}" -n "${NEXUS_NS}" exec deploy/nexus -- test -f /nexus-data/admin.password 2>/dev/null; then
  NEW_PASS="${NEXUS_ADMIN_PASSWORD:-nexus-admin-change-me}"
  echo "==> setting durable admin password"
  curl -sk "${auth[@]}" -H 'Content-Type: text/plain' \
    -X PUT "${BASE}/service/rest/v1/security/users/admin/change-password" \
    --data-binary "${NEW_PASS}" || true
  ADMIN_PASS="${NEW_PASS}"
  auth=(-u "admin:${ADMIN_PASS}")
fi

create_proxy() {
  local name="$1" remote="$2"
  if curl -sk "${auth[@]}" "${BASE}/service/rest/v1/repositories/maven/proxy/${name}" | jq -e .name >/dev/null 2>&1; then
    echo "  proxy ${name} exists"
    return
  fi
  echo "  creating proxy ${name} → ${remote}"
  curl -sk "${auth[@]}" -H 'Content-Type: application/json' \
    -X POST "${BASE}/service/rest/v1/repositories/maven/proxy" \
    -d "$(jq -n --arg n "$name" --arg r "$remote" '{
      name: $n,
      online: true,
      storage: { blobStoreName: "default", strictContentTypeValidation: true, writePolicy: "ALLOW" },
      proxy: { remoteUrl: $r, contentMaxAge: 1440, metadataMaxAge: 1440 },
      negativeCache: { enabled: true, timeToLive: 1440 },
      httpClient: { blocked: false, autoBlock: true },
      maven: { versionPolicy: "MIXED", layoutPolicy: "PERMISSIVE" }
    }')" >/dev/null
}

echo "==> ensuring Maven proxy repositories"
create_proxy maven-central "https://repo1.maven.org/maven2/"
create_proxy maven-redhat "https://maven.repository.redhat.com/ga/"

# Ensure group includes Red Hat GA (and keep default hosted repos when present).
echo "  upserting group maven-public (central + redhat [+ hosted])"
MEMBERS='["maven-central","maven-redhat"]'
for hosted in maven-releases maven-snapshots; do
  if curl -sk "${auth[@]}" "${BASE}/service/rest/v1/repositories/${hosted}" | jq -e .name >/dev/null 2>&1; then
    MEMBERS="$(jq -cn --argjson m "$MEMBERS" --arg h "$hosted" '$m + [$h]')"
  fi
done
GROUP_BODY="$(jq -cn --argjson members "$MEMBERS" '{
  name: "maven-public",
  online: true,
  storage: { blobStoreName: "default", strictContentTypeValidation: true },
  group: { memberNames: $members },
  maven: { versionPolicy: "MIXED", layoutPolicy: "PERMISSIVE" }
}')"
if curl -sk "${auth[@]}" "${BASE}/service/rest/v1/repositories/maven/group/maven-public" | jq -e .name >/dev/null 2>&1; then
  curl -sk "${auth[@]}" -H 'Content-Type: application/json' \
    -X PUT "${BASE}/service/rest/v1/repositories/maven/group/maven-public" \
    -d "${GROUP_BODY}" >/dev/null
else
  curl -sk "${auth[@]}" -H 'Content-Type: application/json' \
    -X POST "${BASE}/service/rest/v1/repositories/maven/group" \
    -d "${GROUP_BODY}" >/dev/null
fi
echo "  members: $(echo "$MEMBERS" | jq -c .)"

# Anonymous read for demo builds (cluster + Dev Spaces).
echo "==> enabling anonymous access (read)"
curl -sk "${auth[@]}" -H 'Content-Type: application/json' \
  -X PUT "${BASE}/service/rest/v1/security/anonymous" \
  -d '{"enabled":true,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}' >/dev/null || true

echo "==> writing banking-ci/nexus-ci Secret (optional consumers)"
oc --context "${ACM_CONTEXT}" -n "${CI_NS}" create secret generic nexus-ci \
  --from-literal=username=admin \
  --from-literal=password="${ADMIN_PASS}" \
  --from-literal=maven-url="http://nexus.nexus.svc.cluster.local:8081/repository/maven-public/" \
  --from-literal=route-url="${BASE}/repository/maven-public/" \
  --dry-run=client -o yaml | oc --context "${ACM_CONTEXT}" apply -f -

echo
echo "Done."
echo "  UI:           ${BASE}"
echo "  Group (cluster): http://nexus.nexus.svc.cluster.local:8081/repository/maven-public/"
echo "  Group (Route):   ${BASE}/repository/maven-public/"
echo "  Local settings:  ./scripts/generate-maven-settings.sh > ~/.m2/settings.xml"
