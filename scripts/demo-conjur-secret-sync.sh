#!/usr/bin/env bash
# Demo: change a value in Conjur → External Secrets Operator syncs the K8s Secret.
#
# Default target (hub, always available after bootstrap):
#   Conjur:  banking/jenkins/jenkins-admin-password
#   Secret:  banking-ci/jenkins-admin  key jenkins-admin-password
#
# Spoke example (east/west after sync-conjur-creds + apps):
#   VARIABLE=banking/banking-service/SPRING_DATASOURCE_PASSWORD \
#   CONTEXT=east NAMESPACE=banking-apps SECRET=banking-service-db KEY=SPRING_DATASOURCE_PASSWORD \
#   scripts/demo-conjur-secret-sync.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/conjur.sh
source "${ROOT_DIR}/scripts/lib/conjur.sh"

HUB_CTX="${CONJUR_CONTEXT:-acm}"
TARGET_CTX="${CONTEXT:-acm}"
NAMESPACE="${NAMESPACE:-banking-ci}"
SECRET="${SECRET:-jenkins-admin}"
KEY="${KEY:-jenkins-admin-password}"
VARIABLE="${VARIABLE:-banking/jenkins/jenkins-admin-password}"
NEW_VALUE="${NEW_VALUE:-}"
RESTORE="${RESTORE:-true}"

usage() {
  cat <<'EOF'
Usage: scripts/demo-conjur-secret-sync.sh

Env overrides:
  VARIABLE     Conjur variable id (default banking/jenkins/jenkins-admin-password)
  CONTEXT      kube context for the ExternalSecret/Secret (default acm)
  NAMESPACE    K8s namespace (default banking-ci)
  SECRET       K8s Secret name (default jenkins-admin)
  KEY          Secret data key (default jenkins-admin-password)
  NEW_VALUE    Value to write (default: demo-<timestamp>)
  RESTORE      true|false — restore previous Conjur value at end (default true)
  CONJUR_CONTEXT  kube context where Conjur runs (default acm)

Example (spoke banking-service password):
  VARIABLE=banking/banking-service/SPRING_DATASOURCE_PASSWORD \
  CONTEXT=east NAMESPACE=banking-apps SECRET=banking-service-db \
  KEY=SPRING_DATASOURCE_PASSWORD \
  scripts/demo-conjur-secret-sync.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${NEW_VALUE}" ]]; then
  NEW_VALUE="demo-sync-$(date +%Y%m%d%H%M%S)"
fi

echo "==> Conjur secret sync demo"
echo "    variable : ${VARIABLE}"
echo "    target   : ${TARGET_CTX}/${NAMESPACE}/${SECRET}.${KEY}"
echo "    new value: ${NEW_VALUE}"

# Discover ExternalSecret that owns the target Secret (same name by convention in this demo)
ES_NAME="${EXTERNAL_SECRET:-${SECRET}}"
if [[ "${SECRET}" == "jenkins-admin" ]]; then
  ES_NAME="jenkins-admin"
elif [[ "${SECRET}" == "github-ci" ]]; then
  ES_NAME="github-ci"
elif [[ "${SECRET}" == "banking-service-db" ]]; then
  ES_NAME="banking-service-db"
elif [[ "${SECRET}" == "postgresql-credentials" ]]; then
  ES_NAME="postgresql-credentials"
fi

conjur_init

BEFORE="$(conjur_get_var "${VARIABLE}" || true)"
echo "    conjur before (len=${#BEFORE}): ${BEFORE:0:6}…"

K8S_BEFORE="$(oc --context "${TARGET_CTX}" -n "${NAMESPACE}" get secret "${SECRET}" \
  -o "jsonpath={.data.${KEY}}" 2>/dev/null | base64 -d || true)"
echo "    k8s before   (len=${#K8S_BEFORE}): ${K8S_BEFORE:0:6}…"

echo "==> Writing new value to Conjur"
conjur_set_var "${VARIABLE}" "${NEW_VALUE}"

echo "==> Forcing ExternalSecret ${ES_NAME} reconcile on ${TARGET_CTX}"
eso_force_sync "${TARGET_CTX}" "${NAMESPACE}" "${ES_NAME}"

echo "==> Waiting for K8s Secret to match Conjur"
eso_wait_secret_key "${TARGET_CTX}" "${NAMESPACE}" "${SECRET}" "${KEY}" "${NEW_VALUE}" 180

AFTER_CONJUR="$(conjur_get_var "${VARIABLE}")"
AFTER_K8S="$(oc --context "${TARGET_CTX}" -n "${NAMESPACE}" get secret "${SECRET}" \
  -o "jsonpath={.data.${KEY}}" | base64 -d)"

echo
echo "RESULT: Conjur and Kubernetes Secret are in sync."
echo "  conjur=${AFTER_CONJUR}"
echo "  k8s   =${AFTER_K8S}"

if [[ "${RESTORE}" == "true" && -n "${BEFORE}" ]]; then
  echo "==> Restoring previous Conjur value"
  conjur_set_var "${VARIABLE}" "${BEFORE}"
  eso_force_sync "${TARGET_CTX}" "${NAMESPACE}" "${ES_NAME}"
  eso_wait_secret_key "${TARGET_CTX}" "${NAMESPACE}" "${SECRET}" "${KEY}" "${BEFORE}" 180 || \
    echo "WARN: restore sync timed out; value is in Conjur — ESO will catch up on refreshInterval"
  echo "Restored."
fi

echo
echo "Demo complete. Apps never talk to Conjur; only ESO materializes Secrets."
