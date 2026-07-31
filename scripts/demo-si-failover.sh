#!/usr/bin/env bash
# Live demo: Service Interconnect backend failover via OpenShift Routes.
#
# Isolated from the mesh demo (banking-apps). Uses:
#   banking-si-apps / banking-si-db
#
# Presenter flow (press Enter between steps):
#   1) Open Skupper Network Observer console (west) — sites, links, traffic
#   2) Continuous traffic via east OpenShift Route
#   3) Drain east banking-service — SI fails over (gateway stays up; X-Banking-Cluster=west)
#   4) Drain east api-gateway — east Route fails; west Route still works
#   5) Recover
#
# Usage:
#   ./scripts/demo-si-failover.sh
#   ./scripts/demo-si-failover.sh preflight|traffic|fail-backend|fail-ingress|recover|status|console
#
# Env:
#   FAIL_CLUSTER=east ENTRY_CLUSTER=east HUB_CONTEXT=acm
#   SI_NS=banking-si-apps
set -euo pipefail

HUB_CONTEXT="${HUB_CONTEXT:-acm}"
FAIL_CLUSTER="${FAIL_CLUSTER:-east}"
ENTRY_CLUSTER="${ENTRY_CLUSTER:-east}"
PEER_CLUSTER="${PEER_CLUSTER:-}"
INTERVAL="${INTERVAL:-1}"
SI_NS="${SI_NS:-banking-si-apps}"
CLIENT_ID="${BANKING_CLIENT_ID:-banking-cli}"
USER="${BANKING_USER:-teller}"
PASS="${BANKING_PASSWORD:-teller-change-me}"
DETAIL_LOG="${DETAIL_LOG:-$(pwd)/.demo-si-failover.log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

say() { printf '  %s\n' "$*"; }

detail() { printf '%s\n' "$*" >> "${DETAIL_LOG}"; }

explain_status_line() {
  cat <<'EOF'

How to read the status line on screen:
  HTTP          → 200 means the API answered (what the audience cares about)
  svc=          → X-Banking-Cluster header (east|west). "?" = image has no header yet
  customers=    → JSON array length from /api/v1/customers
  east_svc / west_svc → readyReplicas of banking-service (SI story)
  east_gw / west_gw   → readyReplicas of api-gateway (ingress story)

Details for every request are appended to the log file (not the status line).

EOF
}

network_observer_guide() {
  local url
  url="$(console_url || true)"
  cat <<EOF

Network Observer (west cluster — login with OpenShift user for WEST):
  ${url:-MISSING — run: ./scripts/si/console-url.sh}

  1) Browser opens the Route on west (not ACM / not Kiali).
  2) Log in with an OpenShift account that can access west.
  3) In the console, open in this order:
       • Topology  → two sites linked (east ↔ west)
       • Sites     → both Ready, sitesInNetwork = 2
       • Components / Addresses → find routing key "banking-service"
  4) SI failover (step 3) is when cross-site traffic is most visible:
       east api-gateway keeps answering, but pods on west serve the work.
  5) Metrics refresh every ~15s — give it a few seconds after traffic starts.

EOF
}

console_url() {
  "${SCRIPT_DIR}/si/console-url.sh" 2>/dev/null || true
}

cluster_route_url() {
  local ctx="$1"
  echo "https://$(oc --context "${ctx}" -n "${SI_NS}" get route api-gateway -o jsonpath='{.spec.host}')"
}

entry_url() { cluster_route_url "${ENTRY_CLUSTER}"; }

keycloak_url() {
  if [[ -n "${KEYCLOAK_URL:-}" ]]; then
    echo "${KEYCLOAK_URL}"
    return
  fi
  local host
  host="$(oc --context "${HUB_CONTEXT}" -n banking-idp get route sso -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  echo "https://${host}"
}

replicas() {
  local ctx="$1" deploy="$2"
  oc --context "${ctx}" -n "${SI_NS}" get deploy "${deploy}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0
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
  local base="$1" token="$2"
  local hdrs body code cluster bytes snippet count
  hdrs="$(mktemp)"
  body="$(mktemp)"
  code="$(curl -sk -D "${hdrs}" -o "${body}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json" \
    "${base}/api/v1/customers" || echo 000)"
  cluster="$(awk 'BEGIN{IGNORECASE=1} /^X-Banking-Cluster:/{gsub(/\r/,""); sub(/^[^:]+:[[:space:]]*/,""); print; exit}' "${hdrs}")"
  [[ -n "${cluster}" ]] || cluster="?"
  bytes="$(wc -c < "${body}" | tr -d ' ')"
  snippet="$(head -c 120 "${body}" | tr '\n' ' ')"
  count="$(jq -r 'if type=="array" then length else "?" end' "${body}" 2>/dev/null || echo "?")"
  detail "---- $(date -u +%Y-%m-%dT%H:%M:%SZ) GET ${base}/api/v1/customers"
  detail "HTTP ${code}  X-Banking-Cluster=${cluster}  customers=${count}  bytes=${bytes}"
  detail "body: ${snippet}"
  rm -f "${hdrs}" "${body}"
  printf '%s|%s|%s|%s\n' "${code}" "${cluster}" "${count}" "${snippet}"
}

show_line() {
  local code="$1" cluster="$2" customers="$3" phase="$4"
  printf '\r\033[K[%s] %s  HTTP %-3s  svc=%-5s  customers=%-3s  east_svc=%s west_svc=%s  east_gw=%s west_gw=%s' \
    "$(date +%H:%M:%S)" "${phase}" "${code}" "${cluster}" "${customers}" \
    "$(replicas east banking-service)" "$(replicas west banking-service)" \
    "$(replicas east api-gateway)" "$(replicas west api-gateway)"
}

pause_argo() {
  local ctx="$1" app="$2"
  oc --context "${ctx}" -n openshift-gitops patch "applications.argoproj.io/${app}" \
    --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null 2>&1 || true
}

resume_argo() {
  local ctx="$1" app="$2"
  oc --context "${ctx}" -n openshift-gitops patch "applications.argoproj.io/${app}" \
    --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null 2>&1 || true
}

init_log() {
  mkdir -p "$(dirname "${DETAIL_LOG}")"
  : > "${DETAIL_LOG}"
  detail "demo-si-failover started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  detail "fail=${FAIL_CLUSTER} peer=${PEER_CLUSTER}"
}

cmd_console() {
  local url
  url="$(console_url)"
  [[ -n "${url}" ]] || { echo "Network Observer console not found" >&2; exit 1; }
  echo "${url}"
  if [[ "${1:-}" == "open" ]] || [[ "${OPEN:-0}" == "1" ]]; then
    "${SCRIPT_DIR}/si/console-url.sh" open
  fi
}

cmd_preflight() {
  init_log
  banner "Preflight — Service Interconnect (OpenShift Routes)"
  echo "Network Observer: $(console_url || echo MISSING)"
  echo "Entry Route:      $(entry_url)"
  echo "Peer Route:       $(cluster_route_url "${PEER_CLUSTER}")"
  echo "Detail log:       ${DETAIL_LOG}"
  echo "Fail / peer:      ${FAIL_CLUSTER} → ${PEER_CLUSTER}"
  echo

  for ctx in east west; do
    printf '  %-5s banking-service=%s  api-gateway=%s  site=%s\n' "${ctx}" \
      "$(replicas "${ctx}" banking-service)" \
      "$(replicas "${ctx}" api-gateway)" \
      "$(oc --context "${ctx}" -n "${SI_NS}" get site banking-si -o jsonpath='{.status.status}' 2>/dev/null || echo missing)"
  done

  echo
  echo "Links (east):"
  oc --context east -n "${SI_NS}" get link 2>/dev/null || echo "  (none — run scripts/si/link-sites.sh)"

  local tok result code cluster base
  tok="$(get_token "$(keycloak_url)")"
  [[ -n "${tok}" ]] || { echo "FAIL: cannot get JWT from hub Keycloak" >&2; exit 1; }
  base="$(entry_url)"
  result="$(call_customers "${base}" "${tok}")"
  code="${result%%|*}"
  cluster="$(echo "${result}" | cut -d'|' -f2)"
  echo
  echo "Baseline via ${base}: HTTP ${code}  X-Banking-Cluster=${cluster}"
  [[ "${code}" =~ ^2 ]] || { echo "FAIL: baseline API not healthy (see ${DETAIL_LOG})" >&2; exit 1; }
  if [[ "${cluster}" == "?" ]]; then
    say "Note: X-Banking-Cluster is '?' until the SI banking-service image includes ClusterIdentityFilter."
    say "Use east_svc/west_svc replica counts + Network Observer for the story."
  fi
  echo "OK — ready for the live demo."
}

cmd_status() {
  banner "Status"
  echo "Console: $(console_url)"
  echo "Entry:   $(entry_url)"
  for ctx in east west; do
    printf '%-6s svc=%s gw=%s\n' "${ctx}" \
      "$(replicas "${ctx}" banking-service)" \
      "$(replicas "${ctx}" api-gateway)"
  done
  local tok result
  tok="$(get_token "$(keycloak_url)")"
  result="$(call_customers "$(entry_url)" "${tok}")"
  echo "API: HTTP ${result%%|*}  cluster=$(echo "${result}" | cut -d'|' -f2)  via $(entry_url)"
}

traffic_loop() {
  local phase="$1" base="$2" kc="$3"
  local tok result code cluster ok=0 fail=0 customers
  tok="$(get_token "${kc}")"
  [[ -n "${tok}" ]] || { echo "[${phase}] no token"; return 1; }
  echo "Traffic → ${base}"
  echo "Screen: one status line | details → ${DETAIL_LOG}"
  echo "CTRL+C to stop."
  echo
  while true; do
    result="$(call_customers "${base}" "${tok}")"
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
  banner "Traffic — watch Network Observer"
  echo "Console: $(console_url)"
  echo
  traffic_loop "traffic" "$(entry_url)" "$(keycloak_url)"
}

sample_window() {
  local phase="$1" base="$2" n="${3:-25}"
  local kc tok result code cluster ok=0 fail=0 customers i last_cluster="?"
  kc="$(keycloak_url)"
  tok="$(get_token "${kc}")"
  for i in $(seq 1 "${n}"); do
    result="$(call_customers "${base}" "${tok}")"
    code="${result%%|*}"
    cluster="$(echo "${result}" | cut -d'|' -f2)"
    customers="$(echo "${result}" | cut -d'|' -f3)"
    last_cluster="${cluster}"
    if [[ "${code}" =~ ^2 ]]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    show_line "${code}" "${cluster}" "${customers}" "${phase} ${i}/${n}"
    sleep 1
  done
  echo
  echo
  echo "Result: ok=${ok} fail=${fail}  last X-Banking-Cluster=${last_cluster}"
}

wait_connector_drained() {
  local ctx="$1"
  local i st
  echo "Waiting for ${ctx} Connector banking-service to report no local pods..."
  for i in $(seq 1 30); do
    st="$(oc --context "${ctx}" -n "${SI_NS}" get connector banking-service -o jsonpath='{.status.status}' 2>/dev/null || true)"
    if [[ "${st}" == "Error" ]]; then
      echo "  Connector status=${st} (local pods gone; SI should use ${PEER_CLUSTER})"
      return 0
    fi
    sleep 2
  done
  echo "  WARN: Connector did not reach Error status (last=${st:-unknown}); sampling anyway" >&2
}

cmd_fail_backend() {
  init_log
  banner "FAIL backend — Service Interconnect failover"
  say "Story: kill ${FAIL_CLUSTER} banking-service pods. Keep calling the ${ENTRY_CLUSTER} api-gateway Route."
  say "Expect: HTTP stays 200. east_svc→0, west_svc stays 1. Skupper forwards to ${PEER_CLUSTER}."
  say "Watch: Network Observer → Topology / banking-service (cross-site bytes/connections)."
  echo
  say "Pausing Argo self-heal; scaling ${FAIL_CLUSTER}/banking-service → 0"
  pause_argo "${FAIL_CLUSTER}" banking-si-service
  oc --context "${FAIL_CLUSTER}" -n "${SI_NS}" scale deploy/banking-service --replicas=0
  wait_connector_drained "${FAIL_CLUSTER}"
  echo
  explain_status_line
  say "Sampling via ${ENTRY_CLUSTER} OpenShift Route so SI is the only failover path."
  echo
  sample_window "si-failover" "$(entry_url)" 25
  local tok result code
  tok="$(get_token "$(keycloak_url)")"
  result="$(call_customers "$(entry_url)" "${tok}")"
  code="${result%%|*}"
  if [[ "${code}" =~ ^2 ]] && [[ "$(replicas "${FAIL_CLUSTER}" banking-service)" == "0" || -z "$(replicas "${FAIL_CLUSTER}" banking-service)" ]]; then
    echo "✓ SI kept the API up: gateway on ${ENTRY_CLUSTER}, backend work on ${PEER_CLUSTER}"
  else
    echo "⚠ Expected HTTP 2xx via ${ENTRY_CLUSTER} gateway with local banking-service at 0 (got HTTP ${code})"
  fi
}

cmd_fail_ingress() {
  init_log
  banner "FAIL ingress — OpenShift Routes (no shared DNS)"
  say "Story: kill ${FAIL_CLUSTER} api-gateway. ${FAIL_CLUSTER} Route fails; ${PEER_CLUSTER} Route still works."
  echo
  say "Pausing Argo; scaling ${FAIL_CLUSTER}/api-gateway → 0"
  pause_argo "${FAIL_CLUSTER}" banking-si-gateway
  oc --context "${FAIL_CLUSTER}" -n "${SI_NS}" scale deploy/api-gateway --replicas=0
  echo
  local tok result_fail result_peer
  tok="$(get_token "$(keycloak_url)")"
  say "Calling ${FAIL_CLUSTER} Route (should fail)…"
  result_fail="$(call_customers "$(cluster_route_url "${FAIL_CLUSTER}")" "${tok}")"
  say "  ${FAIL_CLUSTER}: HTTP ${result_fail%%|*}"
  say "Calling ${PEER_CLUSTER} Route (should work)…"
  result_peer="$(call_customers "$(cluster_route_url "${PEER_CLUSTER}")" "${tok}")"
  say "  ${PEER_CLUSTER}: HTTP ${result_peer%%|*}  svc=$(echo "${result_peer}" | cut -d'|' -f2)"
  echo
  if [[ ! "${result_fail%%|*}" =~ ^2 ]] && [[ "${result_peer%%|*}" =~ ^2 ]]; then
    echo "✓ Use the peer cluster OpenShift Route when ${FAIL_CLUSTER} ingress is down."
  else
    echo "⚠ Unexpected results — check Routes and api-gateway pods."
  fi
}

cmd_recover() {
  banner "RECOVER — restore ${FAIL_CLUSTER}"
  oc --context "${FAIL_CLUSTER}" -n "${SI_NS}" scale deploy/banking-service --replicas=1
  oc --context "${FAIL_CLUSTER}" -n "${SI_NS}" scale deploy/api-gateway --replicas=1
  resume_argo "${FAIL_CLUSTER}" banking-si-service
  resume_argo "${FAIL_CLUSTER}" banking-si-gateway
  oc --context "${FAIL_CLUSTER}" -n "${SI_NS}" rollout status deploy/banking-service --timeout=180s
  oc --context "${FAIL_CLUSTER}" -n "${SI_NS}" rollout status deploy/api-gateway --timeout=180s
  local tok result
  tok="$(get_token "$(keycloak_url)")"
  result="$(call_customers "$(entry_url)" "${tok}")"
  echo "API HTTP ${result%%|*}  cluster=$(echo "${result}" | cut -d'|' -f2)"
  echo "Restored. Both sites should look healthy in Network Observer."
}

cmd_demo() {
  banner "Live demo — what you will prove"
  say "1) Service Interconnect: backend dies on ${FAIL_CLUSTER}, API still works via Skupper."
  say "2) Ingress: east Route dies → call the west OpenShift Route (no shared DNS)."
  say "Entry: $(entry_url)"
  explain_status_line
  pause

  cmd_preflight
  pause

  banner "Step 1 — Open Network Observer (before traffic)"
  network_observer_guide
  "${SCRIPT_DIR}/si/console-url.sh" open 2>/dev/null || true
  say "Log in now. Confirm Topology shows two linked sites. Then press Enter."
  pause

  banner "Step 2 — Baseline traffic (${ENTRY_CLUSTER} Route)"
  say "Calling: $(entry_url)"
  say "Log file: ${DETAIL_LOG}"
  say "Leave Network Observer on Topology / banking-service while requests run."
  explain_status_line
  pause

  local base kc tid
  base="$(entry_url)"
  kc="$(keycloak_url)"
  say "Sending traffic for ~12s so Observer can scrape metrics…"
  traffic_loop "baseline" "${base}" "${kc}" &
  tid=$!
  trap 'kill ${tid} 2>/dev/null || true; echo' EXIT

  sleep 12
  echo
  say "Traffic is running in the background. Glance at Network Observer, then press Enter for SI failover."
  pause

  banner "Step 3 — SI failover (backend)"
  kill "${tid}" 2>/dev/null || true
  wait "${tid}" 2>/dev/null || true
  trap - EXIT
  echo
  say "Look at Network Observer NOW — this is the Skupper moment."
  NONINTERACTIVE=1 cmd_fail_backend
  pause

  banner "Step 4 — Ingress (peer OpenShift Route)"
  say "Proof here is the terminal: east Route fails, west Route stays HTTP 200."
  NONINTERACTIVE=1 cmd_fail_ingress
  pause

  banner "Step 5 — Recover"
  NONINTERACTIVE=1 cmd_recover
  banner "Demo complete"
  say "Console: $(console_url)"
  say "Entry:   $(entry_url)"
  say "Log:     ${DETAIL_LOG}"
  echo
  say "Mesh contrast (Kiali on ACM): ./scripts/demo-mesh-failover.sh"
}

case "${1:-demo}" in
  preflight)     cmd_preflight ;;
  traffic)       cmd_traffic ;;
  fail-backend)  cmd_fail_backend ;;
  fail-dns|fail-ingress) cmd_fail_ingress ;;
  recover)       cmd_recover ;;
  status)        cmd_status ;;
  console)       cmd_console "${2:-}" ;;
  demo)          cmd_demo ;;
  *)
    echo "Usage: $0 {demo|preflight|traffic|fail-backend|fail-ingress|recover|status|console}" >&2
    exit 1
    ;;
esac
