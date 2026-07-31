#!/usr/bin/env bash
# Copy hub Quay robot credentials to managed clusters as docker-registry Secret quay-pull.
set -euo pipefail

ACM_CONTEXT="${ACM_CONTEXT:-acm}"
MANAGED_CONTEXTS="${MANAGED_CONTEXTS:-east west}"
CI_NS="${CI_NS:-banking-ci}"
# Mesh demo + Service Interconnect demo namespaces (space-separated).
APP_NS_LIST="${APP_NS_LIST:-banking-apps banking-si-apps}"
# Backward compatible: APP_NS overrides the list when set explicitly by callers.
if [[ -n "${APP_NS:-}" ]]; then
  APP_NS_LIST="${APP_NS}"
fi
QUAY_NS="${QUAY_NS:-quay-enterprise}"

USER="$(oc --context "${ACM_CONTEXT}" -n "${CI_NS}" get secret quay-ci -o jsonpath='{.data.username}' | base64 -d)"
PASS="$(oc --context "${ACM_CONTEXT}" -n "${CI_NS}" get secret quay-ci -o jsonpath='{.data.password}' | base64 -d)"
HOST="$(oc --context "${ACM_CONTEXT}" -n "${QUAY_NS}" get route -l quay-component=quay-app-route \
  -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
if [[ -z "${HOST}" ]]; then
  HOST="$(oc --context "${ACM_CONTEXT}" -n "${QUAY_NS}" get route banking-quay-quay -o jsonpath='{.spec.host}')"
fi
[[ -n "${USER}" && -n "${PASS}" && -n "${HOST}" ]] || {
  echo "ERROR: missing Quay robot credentials or route on ${ACM_CONTEXT}" >&2
  exit 1
}

for ctx in ${MANAGED_CONTEXTS}; do
  for APP_NS in ${APP_NS_LIST}; do
    echo "==> ${ctx}/${APP_NS} quay-pull (${USER}@${HOST})"
    oc --context "${ctx}" create namespace "${APP_NS}" --dry-run=client -o yaml | oc --context "${ctx}" apply -f - >/dev/null
    oc --context "${ctx}" -n "${APP_NS}" create secret docker-registry quay-pull \
      --docker-server="${HOST}" \
      --docker-username="${USER}" \
      --docker-password="${PASS}" \
      --docker-email="quay-ci@banking-demo.local" \
      --dry-run=client -o yaml | oc --context "${ctx}" apply -f -
    oc --context "${ctx}" -n "${APP_NS}" secrets link default quay-pull --for=pull >/dev/null
  done
done

echo "Done."
