#!/usr/bin/env bash
# Live demo: banking APIs + mesh failover, with Kiali on the ACM hub.
#
# Presenter flow (press Enter between steps):
#   1) Open Kiali (east+west topology)
#   2) Start continuous traffic via east api-gateway
#   3) "Lose" east banking-service (scale to 0) — mesh should fail over to west
#   4) Recover
#
# Usage:
#   ./scripts/demo-mesh-failover.sh           # interactive demo
#   ./scripts/demo-mesh-failover.sh preflight
#   ./scripts/demo-mesh-failover.sh traffic   # traffic only (CTRL+C to stop)
#   ./scripts/demo-mesh-failover.sh fail
#   ./scripts/demo-mesh-failover.sh recover
#   ./scripts/demo-mesh-failover.sh status
#
# Env:
#   FAIL_CLUSTER=east          # spoke whose banking-service is drained
#   ENTRY_CLUSTER=east         # spoke whose api-gateway / Keycloak the client uses
#   HUB_CONTEXT=acm
#   INTERVAL=1                 # seconds between API calls
set -euo pipefail

HUB_CONTEXT="${HUB_CONTEXT:-acm}"
FAIL_CLUSTER="${FAIL_CLUSTER:-east}"
ENTRY_CLUSTER="${ENTRY_CLUSTER:-east}"
PEER_CLUSTER="${PEER_CLUSTER:-}"
INTERVAL="${INTERVAL:-1}"
BANKING_NS="${BANKING_NS:-banking-apps}"
CLIENT_ID="${BANKING_CLIENT_ID:-banking-cli}"
USER="${BANKING_USER:-teller}"
PASS="${BANKING_PASSWORD:-teller-change-me}"

if [[ -z "${PEER_CLUSTER}" ]]; then
  if [[ "${FAIL_CLUSTER}" == "east" ]]; then PEER_CLUSTER=west; else PEER_CLUSTER=east; fi
fi

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need oc; need curl; need jq

pause() {
  if [[ -t 0 && "${NONINTERACTIVE:-0}" != "1" ]]; then
    read -r -p $'\n▶ Press Enter to continue... ' _
  fi
}

banner() {
  echo
  echo "════════════════════════════════════════════════════════"
  echo " $*"
  echo "════════════════════════════════════════════════════════"
}

kiali_url() {
  local host
  host="$(oc --context "${HUB_CONTEXT}" -n istio-system get route kiali -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${host}" ]]; then
    echo "https://${host}"
  fi
}

gateway_url() {
  local ctx="$1"
  echo "https://$(oc --context "${ctx}" -n "${BANKING_NS}" get route api-gateway -o jsonpath='{.spec.host}')"
}

keycloak_url() {
  local ctx="$1"
  # Single IdP on the hub (acm): trusted-profile-analyzer/sso
  echo "https://$(oc --context "${HUB_CONTEXT}" -n trusted-profile-analyzer get route sso -o jsonpath='{.spec.host}')"
}

get_token() {
  local kc="$1"
  curl -sk -X POST "${kc}/realms/banking/protocol/openid-connect/token" \
    -d "client_id=${CLIENT_ID}" \
    -d "username=${USER}" \
    -d "password=${PASS}" \
    -d "grant_type=password" | jq -r '.access_token // empty'
}

call_customers() {
  local gw="$1" token="$2"
  local code body
  body="$(mktemp)"
  code="$(curl -sk -o "${body}" -w '%{http_code}' -H "Authorization: Bearer ${token}" \
    "${gw}/api/v1/customers" || echo 000)"
  echo "${code}"
  rm -f "${body}"
}

pause_argo() {
  local ctx="$1"
  oc --context "${ctx}" -n openshift-gitops patch applications.argoproj.io banking-service \
    --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null 2>&1 || true
}

resume_argo() {
  local ctx="$1"
  oc --context "${ctx}" -n openshift-gitops patch applications.argoproj.io banking-service \
    --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null 2>&1 || true
}

cmd_preflight() {
  banner "Preflight"
  local kiali
  kiali="$(kiali_url)"
  echo "Kiali (hub):     ${kiali:-MISSING — run scripts/mesh/sync-kiali-multicluster-secrets.sh}"
  echo "Entry cluster:   ${ENTRY_CLUSTER}  gateway=$(gateway_url "${ENTRY_CLUSTER}")"
  echo "Fail cluster:    ${FAIL_CLUSTER}"
  echo "Peer cluster:    ${PEER_CLUSTER}  gateway=$(gateway_url "${PEER_CLUSTER}")"

  for ctx in "${ENTRY_CLUSTER}" "${PEER_CLUSTER}"; do
    local ready
    ready="$(oc --context "${ctx}" -n "${BANKING_NS}" get deploy banking-service \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    echo "banking-service/${ctx}: readyReplicas=${ready:-0}"
  done

  local secrets
  secrets="$(oc --context "${HUB_CONTEXT}" -n istio-system get secret \
    -l kiali.io/multiCluster=true -o name 2>/dev/null | wc -l | tr -d ' ')"
  echo "Kiali remote secrets: ${secrets}"

  local tok
  tok="$(get_token "$(keycloak_url "${ENTRY_CLUSTER}")")"
  [[ -n "${tok}" ]] || { echo "FAIL: cannot get JWT from ${ENTRY_CLUSTER} Keycloak" >&2; exit 1; }
  local code
  code="$(call_customers "$(gateway_url "${ENTRY_CLUSTER}")" "${tok}")"
  echo "Baseline GET /api/v1/customers via ${ENTRY_CLUSTER}: HTTP ${code}"
  [[ "${code}" =~ ^2 ]] || { echo "FAIL: baseline API not healthy" >&2; exit 1; }
  echo "OK"
}

cmd_status() {
  banner "Status"
  echo "Kiali: $(kiali_url)"
  for ctx in east west; do
    printf '%-6s banking-service replicas=%s ready=%s\n' "${ctx}" \
      "$(oc --context "${ctx}" -n "${BANKING_NS}" get deploy banking-service -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?')" \
      "$(oc --context "${ctx}" -n "${BANKING_NS}" get deploy banking-service -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo '?')"
  done
  local tok code
  tok="$(get_token "$(keycloak_url "${ENTRY_CLUSTER}")")"
  code="$(call_customers "$(gateway_url "${ENTRY_CLUSTER}")" "${tok}")"
  echo "Entry ${ENTRY_CLUSTER} API: HTTP ${code}"
  tok="$(get_token "$(keycloak_url "${PEER_CLUSTER}")")"
  code="$(call_customers "$(gateway_url "${PEER_CLUSTER}")" "${tok}")"
  echo "Peer  ${PEER_CLUSTER} API: HTTP ${code}"
}

traffic_loop() {
  local label="$1" gw="$2" kc="$3"
  local tok code ok=0 fail=0
  tok="$(get_token "${kc}")"
  [[ -n "${tok}" ]] || { echo "[${label}] no token"; return 1; }
  while true; do
    code="$(call_customers "${gw}" "${tok}")"
    if [[ "${code}" =~ ^2 ]]; then
      ok=$((ok + 1))
      printf '[%s] %s HTTP %s  ok=%d fail=%d\n' "$(date +%H:%M:%S)" "${label}" "${code}" "${ok}" "${fail}"
    else
      fail=$((fail + 1))
      printf '[%s] %s HTTP %s  ok=%d fail=%d  ← check Kiali graph\n' "$(date +%H:%M:%S)" "${label}" "${code}" "${ok}" "${fail}"
      # refresh token on auth failures
      if [[ "${code}" == "401" || "${code}" == "403" ]]; then
        tok="$(get_token "${kc}")"
      fi
    fi
    sleep "${INTERVAL}"
  done
}

cmd_traffic() {
  banner "Traffic — watch Kiali"
  local kiali gw kc
  kiali="$(kiali_url)"
  gw="$(gateway_url "${ENTRY_CLUSTER}")"
  kc="$(keycloak_url "${ENTRY_CLUSTER}")"
  echo "Open Kiali → Applications → banking-apps → banking-service"
  echo "  ${kiali}"
  echo "  Graph: namespace=banking-apps  versioned app graph  clusters=east,west"
  echo
  echo "Traffic via ${ENTRY_CLUSTER} gateway (mesh → banking-service)."
  echo "CTRL+C to stop."
  echo
  traffic_loop "${ENTRY_CLUSTER}" "${gw}" "${kc}"
}

cmd_fail() {
  banner "FAIL — drain banking-service on ${FAIL_CLUSTER}"
  echo "Pausing ArgoCD self-heal on ${FAIL_CLUSTER}/banking-service..."
  pause_argo "${FAIL_CLUSTER}"
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" scale deploy/banking-service --replicas=0
  echo "Scaled ${FAIL_CLUSTER}/banking-service → 0"
  echo
  echo "In Kiali: banking-service on ${FAIL_CLUSTER} should go unhealthy / empty;"
  echo "remote endpoints on ${PEER_CLUSTER} remain. Mesh DestinationRule"
  echo "(outlierDetection + locality failover) should shift traffic to ${PEER_CLUSTER}."
  echo
  echo "Sampling entry-cluster API for 20s..."
  local gw kc tok code ok=0 fail=0 i
  gw="$(gateway_url "${ENTRY_CLUSTER}")"
  kc="$(keycloak_url "${ENTRY_CLUSTER}")"
  tok="$(get_token "${kc}")"
  for i in $(seq 1 20); do
    code="$(call_customers "${gw}" "${tok}")"
    if [[ "${code}" =~ ^2 ]]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    printf '  [%02d] HTTP %s\n' "${i}" "${code}"
    sleep 1
  done
  echo "Result via ${ENTRY_CLUSTER} gateway: ok=${ok} fail=${fail}"
  if [[ "${ok}" -gt 0 ]]; then
    echo "✓ Mesh failover serving APIs through ${ENTRY_CLUSTER} → ${PEER_CLUSTER} banking-service"
  else
    echo "⚠ Entry path still failing — check EW gateway / shared CA / ambient multi-network."
    echo "  Peer ${PEER_CLUSTER} should still answer locally:"
    tok="$(get_token "$(keycloak_url "${PEER_CLUSTER}")")"
    code="$(call_customers "$(gateway_url "${PEER_CLUSTER}")" "${tok}")"
    echo "  ${PEER_CLUSTER} gateway HTTP ${code}"
  fi
}

cmd_recover() {
  banner "RECOVER — restore banking-service on ${FAIL_CLUSTER}"
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" scale deploy/banking-service --replicas=1
  resume_argo "${FAIL_CLUSTER}"
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" rollout status deploy/banking-service --timeout=180s
  local tok code
  tok="$(get_token "$(keycloak_url "${ENTRY_CLUSTER}")")"
  code="$(call_customers "$(gateway_url "${ENTRY_CLUSTER}")" "${tok}")"
  echo "Entry API HTTP ${code}"
  echo "Restored. Resume traffic and confirm both clusters in Kiali."
}

cmd_demo() {
  cmd_preflight
  pause

  banner "Step 1 — Open Kiali (centralized on ACM)"
  echo "$(kiali_url)"
  echo
  echo "Suggested view:"
  echo "  • Overview: clusters east + west visible"
  echo "  • Graph → namespace banking-apps → show all clusters"
  echo "  • Select banking-service (workloads on east and west)"
  pause

  banner "Step 2 — Generate live traffic (background)"
  echo "Starting traffic loop via ${ENTRY_CLUSTER} (log below)."
  echo "Leave this terminal visible; open Kiali beside it."
  pause

  local gw kc
  gw="$(gateway_url "${ENTRY_CLUSTER}")"
  kc="$(keycloak_url "${ENTRY_CLUSTER}")"
  traffic_loop "${ENTRY_CLUSTER}" "${gw}" "${kc}" &
  local tid=$!
  trap 'kill ${tid} 2>/dev/null || true' EXIT

  sleep 5
  pause

  banner "Step 3 — Lose ${FAIL_CLUSTER} banking-service (mesh failover)"
  kill "${tid}" 2>/dev/null || true
  wait "${tid}" 2>/dev/null || true
  trap - EXIT
  NONINTERACTIVE=1 cmd_fail
  pause

  banner "Step 4 — Recover"
  NONINTERACTIVE=1 cmd_recover
  banner "Demo complete"
  echo "Kiali: $(kiali_url)"
}

case "${1:-demo}" in
  preflight) cmd_preflight ;;
  traffic)   cmd_traffic ;;
  fail)      cmd_fail ;;
  recover)   cmd_recover ;;
  status)    cmd_status ;;
  demo)      cmd_demo ;;
  *)
    echo "Usage: $0 {demo|preflight|traffic|fail|recover|status}" >&2
    exit 1
    ;;
esac
