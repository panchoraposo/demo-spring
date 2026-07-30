#!/usr/bin/env bash
# Live demo: banking APIs + mesh failover, with Kiali on the ACM hub.
#
# Screen stays compact (one status line). Verbose request/response details go to
# a log file you can open if needed — keep the terminal + Kiali visible.
#
# Presenter flow (press Enter between steps):
#   1) Open Kiali (east+west topology, namespaces banking-apps + banking-db)
#   2) Start continuous traffic via east api-gateway
#   3) Drain east banking-service — mesh fails over to west (API stays 200)
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
#   FAIL_CLUSTER=east          # cluster whose banking-service is drained
#   ENTRY_CLUSTER=east         # cluster whose api-gateway the client uses
#   HUB_CONTEXT=acm
#   INTERVAL=1                 # seconds between API calls
#   DETAIL_LOG=./.demo-failover.log
set -euo pipefail

HUB_CONTEXT="${HUB_CONTEXT:-acm}"
FAIL_CLUSTER="${FAIL_CLUSTER:-east}"
ENTRY_CLUSTER="${ENTRY_CLUSTER:-east}"
PEER_CLUSTER="${PEER_CLUSTER:-}"
INTERVAL="${INTERVAL:-1}"
BANKING_NS="${BANKING_NS:-banking-apps}"
DB_NS="${DB_NS:-banking-db}"
CLIENT_ID="${BANKING_CLIENT_ID:-banking-cli}"
USER="${BANKING_USER:-teller}"
PASS="${BANKING_PASSWORD:-teller-change-me}"
DETAIL_LOG="${DETAIL_LOG:-$(pwd)/.demo-failover.log}"

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

detail() {
  # Full detail for the log file only (not the presenter screen).
  printf '%s\n' "$*" >> "${DETAIL_LOG}"
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
  # Prefer explicit URL; else hub Route; else issuer host from a known managed-cluster ConfigMap.
  if [[ -n "${KEYCLOAK_URL:-}" ]]; then
    echo "${KEYCLOAK_URL}"
    return
  fi
  local host
  host="$(oc --context "${HUB_CONTEXT}" -n banking-idp get route sso -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "${host}" ]]; then
    host="$(oc --context "${ENTRY_CLUSTER}" -n "${BANKING_NS}" get cm api-gateway-config \
      -o jsonpath='{.data.SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI}' 2>/dev/null \
      | sed -E 's|^https?://||; s|/realms/.*||')"
  fi
  echo "https://${host}"
}

replicas() {
  local ctx="$1"
  oc --context "${ctx}" -n "${BANKING_NS}" get deploy banking-service \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0
}

ns_mesh_label() {
  local ctx="$1" ns="$2"
  oc --context "${ctx}" get ns "${ns}" \
    -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null || true
}

get_token() {
  local kc="$1"
  curl -sk -X POST "${kc}/realms/banking/protocol/openid-connect/token" \
    -d "client_id=${CLIENT_ID}" \
    -d "username=${USER}" \
    -d "password=${PASS}" \
    -d "grant_type=password" | jq -r '.access_token // empty'
}

# Returns: code|cluster|bytes|snippet  (cluster from X-Banking-Cluster when present)
call_customers() {
  local gw="$1" token="$2"
  local hdrs body code cluster bytes snippet
  hdrs="$(mktemp)"
  body="$(mktemp)"
  code="$(curl -sk -D "${hdrs}" -o "${body}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json" \
    "${gw}/api/v1/customers" || echo 000)"
  cluster="$(awk 'BEGIN{IGNORECASE=1} /^X-Banking-Cluster:/{gsub(/\r/,""); sub(/^[^:]+:[[:space:]]*/,""); print; exit}' "${hdrs}")"
  [[ -n "${cluster}" ]] || cluster="?"
  bytes="$(wc -c < "${body}" | tr -d ' ')"
  snippet="$(head -c 120 "${body}" | tr '\n' ' ')"
  count="$(jq -r 'if type=="array" then length else "?" end' "${body}" 2>/dev/null || echo "?")"
  detail "---- $(date -u +%Y-%m-%dT%H:%M:%SZ) GET ${gw}/api/v1/customers"
  detail "HTTP ${code}  X-Banking-Cluster=${cluster}  customers=${count}  bytes=${bytes}"
  detail "body: ${snippet}"
  detail "headers:"
  detail "$(grep -E -i '^(HTTP/|x-banking-cluster:|content-type:|server:|x-envoy)' "${hdrs}" | tr -d '\r' || true)"
  rm -f "${hdrs}" "${body}"
  printf '%s|%s|%s|%s\n' "${code}" "${cluster}" "${count}" "${snippet}"
}

# Compact single-line status for the presenter screen.
# args: code cluster customers phase
show_line() {
  local code="$1" cluster="$2" customers="$3" phase="$4"
  local east_r west_r
  east_r="$(replicas east)"
  west_r="$(replicas west)"
  # Clear line + print (works in demos without flooding scrollback)
  printf '\r\033[K[%s] %s  HTTP %-3s  svc=%-5s  customers=%-3s  east_ready=%s west_ready=%s' \
    "$(date +%H:%M:%S)" "${phase}" "${code}" "${cluster}" "${customers}" \
    "${east_r:-0}" "${west_r:-0}"
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

init_log() {
  mkdir -p "$(dirname "${DETAIL_LOG}")"
  : > "${DETAIL_LOG}"
  detail "demo-mesh-failover detail log started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  detail "entry=${ENTRY_CLUSTER} fail=${FAIL_CLUSTER} peer=${PEER_CLUSTER}"
}

cmd_preflight() {
  init_log
  banner "Preflight"
  local kiali
  kiali="$(kiali_url)"
  echo "Kiali (hub):   ${kiali:-MISSING}"
  echo "Detail log:    ${DETAIL_LOG}"
  echo "Entry gateway: $(gateway_url "${ENTRY_CLUSTER}")"
  echo "Fail / peer:   ${FAIL_CLUSTER} → ${PEER_CLUSTER}"
  echo

  local ctx ns mode
  for ctx in east west; do
    for ns in "${BANKING_NS}" "${DB_NS}"; do
      mode="$(ns_mesh_label "${ctx}" "${ns}")"
      printf '  %-5s ns/%-12s dataplane-mode=%s\n' "${ctx}" "${ns}" "${mode:-unset}"
      if [[ "${mode}" != "ambient" ]]; then
        echo "    WARN: expected istio.io/dataplane-mode=ambient for mTLS" >&2
      fi
    done
    printf '  %-5s banking-service readyReplicas=%s\n' "${ctx}" "$(replicas "${ctx}")"
  done

  local tok result code cluster
  tok="$(get_token "$(keycloak_url)")"
  [[ -n "${tok}" ]] || { echo "FAIL: cannot get JWT from hub Keycloak" >&2; exit 1; }
  result="$(call_customers "$(gateway_url "${ENTRY_CLUSTER}")" "${tok}")"
  code="${result%%|*}"
  cluster="$(echo "${result}" | cut -d'|' -f2)"
  echo
  echo "Baseline via ${ENTRY_CLUSTER}: HTTP ${code}  X-Banking-Cluster=${cluster}"
  [[ "${code}" =~ ^2 ]] || { echo "FAIL: baseline API not healthy (see ${DETAIL_LOG})" >&2; exit 1; }
  echo "OK — open Kiali graph for banking-apps (and banking-db for DB mTLS edges)."
}

cmd_status() {
  banner "Status"
  echo "Kiali: $(kiali_url)"
  echo "Log:   ${DETAIL_LOG}"
  for ctx in east west; do
    printf '%-6s banking-service ready=%s  apps_mesh=%s  db_mesh=%s\n' "${ctx}" \
      "$(replicas "${ctx}")" \
      "$(ns_mesh_label "${ctx}" "${BANKING_NS}")" \
      "$(ns_mesh_label "${ctx}" "${DB_NS}")"
  done
  local tok result
  tok="$(get_token "$(keycloak_url)")"
  result="$(call_customers "$(gateway_url "${ENTRY_CLUSTER}")" "${tok}")"
  echo "Entry API: HTTP ${result%%|*}  cluster=$(echo "${result}" | cut -d'|' -f2)"
}

traffic_loop() {
  local phase="$1" gw="$2" kc="$3"
  local tok result code cluster ok=0 fail=0
  tok="$(get_token "${kc}")"
  [[ -n "${tok}" ]] || { echo "[${phase}] no token"; return 1; }
  echo "Traffic → ${gw}"
  echo "Screen: one status line | details → ${DETAIL_LOG}"
  echo "CTRL+C to stop."
  echo
  while true; do
    result="$(call_customers "${gw}" "${tok}")"
    code="${result%%|*}"
    cluster="$(echo "${result}" | cut -d'|' -f2)"
    customers="$(echo "${result}" | cut -d'|' -f3)"
    if [[ "${code}" =~ ^2 ]]; then
      ok=$((ok + 1))
      show_line "${code}" "${cluster}" "${customers}" "${phase} ok=${ok}"
    else
      fail=$((fail + 1))
      show_line "${code}" "${cluster}" "${customers}" "${phase} FAIL=${fail}"
      if [[ "${code}" == "401" || "${code}" == "403" ]]; then
        tok="$(get_token "${kc}")"
      fi
    fi
    sleep "${INTERVAL}"
  done
}

cmd_traffic() {
  init_log
  banner "Traffic — watch Kiali"
  local kiali
  kiali="$(kiali_url)"
  echo "Kiali: ${kiali}"
  echo "Graph tip: namespaces banking-apps (+ banking-db), clusters east+west"
  echo
  traffic_loop "traffic" "$(gateway_url "${ENTRY_CLUSTER}")" "$(keycloak_url)"
}

cmd_fail() {
  init_log
  banner "FAIL — drain banking-service on ${FAIL_CLUSTER}"
  echo "Pausing Argo self-heal; scaling ${FAIL_CLUSTER}/banking-service → 0"
  pause_argo "${FAIL_CLUSTER}"
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" scale deploy/banking-service --replicas=0
  echo
  echo "Watch Kiali: ${FAIL_CLUSTER} workload empties; traffic continues via mesh to ${PEER_CLUSTER}."
  echo "Sampling ${ENTRY_CLUSTER} gateway (compact line; details in ${DETAIL_LOG})..."
  echo

  local gw kc tok result code cluster ok=0 fail=0 i
  gw="$(gateway_url "${ENTRY_CLUSTER}")"
  kc="$(keycloak_url)"
  tok="$(get_token "${kc}")"
  for i in $(seq 1 25); do
    result="$(call_customers "${gw}" "${tok}")"
    code="${result%%|*}"
    cluster="$(echo "${result}" | cut -d'|' -f2)"
    customers="$(echo "${result}" | cut -d'|' -f3)"
    if [[ "${code}" =~ ^2 ]]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    show_line "${code}" "${cluster}" "${customers}" "failover ${i}/25"
    sleep 1
  done
  echo
  echo
  echo "Result: ok=${ok} fail=${fail}  (entry=${ENTRY_CLUSTER}, drained=${FAIL_CLUSTER}, peer=${PEER_CLUSTER})"
  if [[ "${ok}" -gt 0 ]]; then
    echo "✓ API kept working through the entry gateway while ${FAIL_CLUSTER} banking-service was scaled to 0"
    echo "  That is service-mesh failover (DestinationRule + ambient multi-network)."
    if [[ "${cluster}" == "${PEER_CLUSTER}" ]]; then
      echo "✓ X-Banking-Cluster=${cluster} confirms responses from the peer"
    elif [[ "${cluster}" == "?" ]]; then
      echo "  Tip: after the next banking-service image build, X-Banking-Cluster will name the serving cluster."
    fi
  else
    echo "⚠ Entry path still failing — see ${DETAIL_LOG}"
    echo "  Check EW gateway / shared CA / ambient multi-network / DestinationRule."
  fi
}

cmd_recover() {
  banner "RECOVER — restore banking-service on ${FAIL_CLUSTER}"
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" scale deploy/banking-service --replicas=1
  resume_argo "${FAIL_CLUSTER}"
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" rollout status deploy/banking-service --timeout=180s
  local tok result
  tok="$(get_token "$(keycloak_url)")"
  result="$(call_customers "$(gateway_url "${ENTRY_CLUSTER}")" "${tok}")"
  echo "Entry API HTTP ${result%%|*}  cluster=$(echo "${result}" | cut -d'|' -f2)"
  echo "Restored. Both clusters should appear healthy in Kiali."
}

cmd_demo() {
  cmd_preflight
  pause

  banner "Step 1 — Open Kiali on ACM"
  echo "$(kiali_url)"
  echo
  echo "Suggested view:"
  echo "  • Graph → namespaces: banking-apps (add banking-db for DB mTLS edges)"
  echo "  • Show clusters east + west"
  echo "  • Focus banking-service (global) + api-gateway"
  pause

  banner "Step 2 — Live traffic (one status line)"
  echo "Terminal stays readable; full responses append to:"
  echo "  ${DETAIL_LOG}"
  pause

  local gw kc
  gw="$(gateway_url "${ENTRY_CLUSTER}")"
  kc="$(keycloak_url)"
  traffic_loop "baseline" "${gw}" "${kc}" &
  local tid=$!
  trap 'kill ${tid} 2>/dev/null || true; echo' EXIT

  sleep 8
  echo
  pause

  banner "Step 3 — Lose ${FAIL_CLUSTER} banking-service"
  kill "${tid}" 2>/dev/null || true
  wait "${tid}" 2>/dev/null || true
  trap - EXIT
  echo
  NONINTERACTIVE=1 cmd_fail
  pause

  banner "Step 4 — Recover"
  NONINTERACTIVE=1 cmd_recover
  banner "Demo complete"
  echo "Kiali: $(kiali_url)"
  echo "Log:   ${DETAIL_LOG}"
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
