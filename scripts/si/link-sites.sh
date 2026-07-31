#!/usr/bin/env bash
# Link east ↔ west Service Interconnect sites in banking-si-apps.
# West is the listening site (AccessGrant); east redeems an AccessToken.
#
# Usage:
#   ./scripts/si/link-sites.sh
#   ./scripts/si/link-sites.sh status
#
# Env:
#   EAST_CONTEXT=east WEST_CONTEXT=west SI_NS=banking-si-apps
set -euo pipefail

EAST_CONTEXT="${EAST_CONTEXT:-east}"
WEST_CONTEXT="${WEST_CONTEXT:-west}"
SI_NS="${SI_NS:-banking-si-apps}"
GRANT_NAME="${GRANT_NAME:-grant-west}"
TOKEN_NAME="${TOKEN_NAME:-token-to-west}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need oc

cmd_status() {
  echo "==> Sites"
  for ctx in "${WEST_CONTEXT}" "${EAST_CONTEXT}"; do
    printf '  %-5s ' "${ctx}"
    oc --context "${ctx}" -n "${SI_NS}" get site banking-si -o wide 2>/dev/null || echo "(missing)"
  done
  echo "==> Links (east)"
  oc --context "${EAST_CONTEXT}" -n "${SI_NS}" get link 2>/dev/null || echo "  (none)"
  echo "==> AccessGrant (west)"
  oc --context "${WEST_CONTEXT}" -n "${SI_NS}" get accessgrant "${GRANT_NAME}" -o wide 2>/dev/null || echo "  (missing)"
  echo "==> Connector / Listener"
  for ctx in "${WEST_CONTEXT}" "${EAST_CONTEXT}"; do
    echo "  --- ${ctx} ---"
    oc --context "${ctx}" -n "${SI_NS}" get connector,listener 2>/dev/null || true
  done
}

cmd_link() {
  echo "==> Waiting for west Site + AccessGrant"
  oc --context "${WEST_CONTEXT}" -n "${SI_NS}" wait --for=condition=Ready site/banking-si --timeout=300s
  oc --context "${WEST_CONTEXT}" -n "${SI_NS}" wait --for=condition=Ready "accessgrant/${GRANT_NAME}" --timeout=300s

  URL="$(oc --context "${WEST_CONTEXT}" -n "${SI_NS}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.url}')"
  CODE="$(oc --context "${WEST_CONTEXT}" -n "${SI_NS}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.code}')"
  CA="$(oc --context "${WEST_CONTEXT}" -n "${SI_NS}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.ca}')"

  [[ -n "${URL}" && -n "${CODE}" && -n "${CA}" ]] || {
    echo "ERROR: AccessGrant ${GRANT_NAME} missing status.url/code/ca" >&2
    exit 1
  }

  echo "==> Waiting for east Site"
  oc --context "${EAST_CONTEXT}" -n "${SI_NS}" wait --for=condition=Ready site/banking-si --timeout=300s

  echo "==> Applying AccessToken ${TOKEN_NAME} on east"
  # shellcheck disable=SC2016
  oc --context "${EAST_CONTEXT}" -n "${SI_NS}" apply -f - <<EOF
apiVersion: skupper.io/v2alpha1
kind: AccessToken
metadata:
  name: ${TOKEN_NAME}
  namespace: ${SI_NS}
  labels:
    app.kubernetes.io/part-of: banking-si-demo
spec:
  url: ${URL}
  code: ${CODE}
  ca: |
$(printf '%s\n' "${CA}" | sed 's/^/    /')
EOF

  echo "==> Waiting for Link Ready + sitesInNetwork=2"
  for i in $(seq 1 60); do
    link_status="$(oc --context "${EAST_CONTEXT}" -n "${SI_NS}" get link -o jsonpath='{.items[0].status.status}' 2>/dev/null || true)"
    east_n="$(oc --context "${EAST_CONTEXT}" -n "${SI_NS}" get site banking-si -o jsonpath='{.status.sitesInNetwork}' 2>/dev/null || echo 0)"
    west_n="$(oc --context "${WEST_CONTEXT}" -n "${SI_NS}" get site banking-si -o jsonpath='{.status.sitesInNetwork}' 2>/dev/null || echo 0)"
    echo "  attempt ${i}: link=${link_status:-pending} east_sites=${east_n} west_sites=${west_n}"
    if [[ "${link_status}" == "Ready" && "${east_n}" == "2" && "${west_n}" == "2" ]]; then
      oc --context "${EAST_CONTEXT}" -n "${SI_NS}" get link
      echo "Sites linked (2-site network)."
      return 0
    fi
    sleep 5
  done
  echo "WARN: Link not Ready yet — check AccessToken / Link status:" >&2
  oc --context "${EAST_CONTEXT}" -n "${SI_NS}" get accesstoken "${TOKEN_NAME}" -o yaml >&2 || true
  oc --context "${EAST_CONTEXT}" -n "${SI_NS}" get link -o yaml >&2 || true
  exit 1
}

case "${1:-link}" in
  link)   cmd_link ;;
  status) cmd_status ;;
  *)
    echo "Usage: $0 {link|status}" >&2
    exit 1
    ;;
esac
