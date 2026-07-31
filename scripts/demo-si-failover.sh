#!/usr/bin/env bash
# Live demo: Service Interconnect backend failover via OpenShift Routes.
#
# Isolated from the mesh demo (banking-apps). Uses:
#   banking-si-apps / banking-si-db
#
# Presenter flow (press Enter between steps):
#   1) Open Skupper Network Observer console (west)
#   2) Baseline traffic via east OpenShift Route
#   3) Drain east banking-service — SI fails over (X-Banking-Cluster → west)
#   4) Drain east api-gateway — east Route fails; west Route still works
#   5) Recover
#
# Usage:
#   ./scripts/demo-si-failover.sh
#   ./scripts/demo-si-failover.sh preflight|traffic|fail-backend|fail-ingress|recover|status|console
#
# Env: FAIL_CLUSTER=east ENTRY_CLUSTER=east HUB_CONTEXT=acm SI_NS=banking-si-apps
set -euo pipefail

HUB_CONTEXT="${HUB_CONTEXT:-acm}"
FAIL_CLUSTER="${FAIL_CLUSTER:-east}"
ENTRY_CLUSTER="${ENTRY_CLUSTER:-east}"
PEER_CLUSTER="${PEER_CLUSTER:-}"
INTERVAL="${INTERVAL:-1}"
SI_NS="${SI_NS:-banking-si-apps}"
BANKING_NS="${SI_NS}"
CLIENT_ID="${BANKING_CLIENT_ID:-banking-cli}"
BANKING_USER="${BANKING_USER:-teller}"
BANKING_PASSWORD="${BANKING_PASSWORD:-teller-change-me}"
DETAIL_LOG="${DETAIL_LOG:-$(pwd)/.demo-si-failover.log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/failover-demo.sh
source "${SCRIPT_DIR}/lib/failover-demo.sh"

if [[ -z "${PEER_CLUSTER}" ]]; then
  PEER_CLUSTER="$(failover_peer_of "${FAIL_CLUSTER}")"
fi

console_url() {
  "${SCRIPT_DIR}/si/console-url.sh" 2>/dev/null || true
}

entry_url() { failover_route_url "${ENTRY_CLUSTER}" "${SI_NS}"; }

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
  failover_init_log "demo-si-failover"
  failover_banner "Preflight — Service Interconnect (OpenShift Routes)"
  echo "Network Observer: $(console_url || echo MISSING)"
  echo "Entry Route:      $(entry_url)"
  echo "Peer Route:       $(failover_route_url "${PEER_CLUSTER}" "${SI_NS}")"
  echo "Detail log:       ${DETAIL_LOG}"
  echo "Fail / peer:      ${FAIL_CLUSTER} → ${PEER_CLUSTER}"
  echo

  local ctx
  for ctx in east west; do
    printf '  %-5s banking-service=%s  api-gateway=%s  site=%s\n' "${ctx}" \
      "$(failover_replicas "${ctx}" "${SI_NS}" banking-service)" \
      "$(failover_replicas "${ctx}" "${SI_NS}" api-gateway)" \
      "$(oc --context "${ctx}" -n "${SI_NS}" get site banking-si -o jsonpath='{.status.status}' 2>/dev/null || echo missing)"
  done

  echo
  echo "Links (east):"
  oc --context east -n "${SI_NS}" get link 2>/dev/null || echo "  (none — run scripts/si/link-sites.sh)"

  local tok result code serving rows base
  tok="$(failover_get_token "$(failover_keycloak_url)")"
  [[ -n "${tok}" ]] || { echo "FAIL: cannot get JWT from hub Keycloak" >&2; exit 1; }
  base="$(entry_url)"
  result="$(failover_call_customers "${base}" "${tok}")"
  code="${result%%|*}"
  serving="$(echo "${result}" | cut -d'|' -f2)"
  rows="$(echo "${result}" | cut -d'|' -f3)"
  echo
  echo "Baseline via ${base}"
  failover_print_route_check "${ENTRY_CLUSTER}" "${result}"
  [[ "${code}" =~ ^2 ]] || { echo "FAIL: baseline API not healthy (see ${DETAIL_LOG})" >&2; exit 1; }
  if [[ "${serving}" == "?" ]]; then
    failover_say "WARN: no X-Banking-Cluster header yet — watch svc e/w counts + Network Observer."
  else
    failover_say "Serving cluster header is working (serving=${serving}, rows=${rows})."
  fi
  echo "OK — ready for the live demo."
  failover_legend
}

cmd_status() {
  failover_banner "Status"
  echo "Console: $(console_url)"
  echo "Entry:   $(entry_url)"
  local ctx
  for ctx in east west; do
    printf '  %-5s svc=%s gw=%s\n' "${ctx}" \
      "$(failover_replicas "${ctx}" "${SI_NS}" banking-service)" \
      "$(failover_replicas "${ctx}" "${SI_NS}" api-gateway)"
  done
  local tok result
  tok="$(failover_get_token "$(failover_keycloak_url)")"
  result="$(failover_call_customers "$(entry_url)" "${tok}")"
  failover_print_route_check entry "${result}"
}

cmd_traffic() {
  failover_init_log "demo-si-failover"
  failover_banner "Traffic — watch Network Observer"
  echo "Console: $(console_url)"
  failover_legend
  failover_traffic_loop "traffic" "$(entry_url)" "${SI_NS}" "$(failover_keycloak_url)"
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
  failover_init_log "demo-si-failover"
  failover_banner "FAIL backend — Service Interconnect failover"
  failover_say "Story: kill ${FAIL_CLUSTER} banking-service. Keep calling the ${ENTRY_CLUSTER} Route."
  failover_say "Expect: API stays OK. svc ${FAIL_CLUSTER}→0, ${PEER_CLUSTER} stays ≥1. serving→${PEER_CLUSTER}."
  failover_say "Watch: Network Observer → Topology / banking-service."
  echo
  failover_say "Pausing Argo self-heal; scaling ${FAIL_CLUSTER}/banking-service → 0"
  failover_pause_argo "${FAIL_CLUSTER}" banking-si-service
  oc --context "${FAIL_CLUSTER}" -n "${SI_NS}" scale deploy/banking-service --replicas=0
  wait_connector_drained "${FAIL_CLUSTER}"
  echo
  failover_legend
  failover_say "Sampling via ${ENTRY_CLUSTER} OpenShift Route (SI is the only failover path)."
  echo
  failover_sample_window "si-failover" "$(entry_url)" "${SI_NS}" 25
  local tok result code serving fail_r
  tok="$(failover_get_token "$(failover_keycloak_url)")"
  result="$(failover_call_customers "$(entry_url)" "${tok}")"
  code="${result%%|*}"
  serving="$(failover_infer_serving "$(echo "${result}" | cut -d'|' -f2)" "${code}" "${SI_NS}")"
  fail_r="$(failover_replicas "${FAIL_CLUSTER}" "${SI_NS}" banking-service)"
  echo
  if [[ "${code}" =~ ^2 ]] && [[ "${fail_r}" == "0" ]]; then
    echo "✓ SI kept the API up: gateway on ${ENTRY_CLUSTER}, backend on ${serving} (want ${PEER_CLUSTER})"
  else
    echo "⚠ Expected API OK via ${ENTRY_CLUSTER} with ${FAIL_CLUSTER} banking-service=0 (got HTTP ${code}, serving=${serving})"
  fi
}

cmd_fail_ingress() {
  failover_init_log "demo-si-failover"
  failover_banner "FAIL ingress — OpenShift Routes (no shared DNS)"
  failover_say "Story: kill ${FAIL_CLUSTER} api-gateway. ${FAIL_CLUSTER} Route fails; ${PEER_CLUSTER} Route works."
  echo
  failover_say "Pausing Argo; scaling ${FAIL_CLUSTER}/api-gateway → 0"
  failover_pause_argo "${FAIL_CLUSTER}" banking-si-gateway
  oc --context "${FAIL_CLUSTER}" -n "${SI_NS}" scale deploy/api-gateway --replicas=0
  echo
  local tok result_fail result_peer
  tok="$(failover_get_token "$(failover_keycloak_url)")"
  failover_say "Calling both OpenShift Routes:"
  result_fail="$(failover_call_customers "$(failover_route_url "${FAIL_CLUSTER}" "${SI_NS}")" "${tok}")"
  failover_print_route_check "${FAIL_CLUSTER}" "${result_fail}"
  result_peer="$(failover_call_customers "$(failover_route_url "${PEER_CLUSTER}" "${SI_NS}")" "${tok}")"
  failover_print_route_check "${PEER_CLUSTER}" "${result_peer}"
  echo
  if [[ ! "${result_fail%%|*}" =~ ^2 ]] && [[ "${result_peer%%|*}" =~ ^2 ]]; then
    echo "✓ Use the peer cluster OpenShift Route when ${FAIL_CLUSTER} ingress is down."
  else
    echo "⚠ Unexpected results — check Routes and api-gateway pods."
  fi
}

cmd_recover() {
  failover_banner "RECOVER — restore ${FAIL_CLUSTER}"
  # Disable local ImageStream rewrite before scale-up (Quay tags are not in the SI IS).
  oc --context "${FAIL_CLUSTER}" -n "${SI_NS}" patch imagestream banking-service \
    --type merge -p '{"spec":{"lookupPolicy":{"local":false}}}' >/dev/null 2>&1 || true

  oc --context "${FAIL_CLUSTER}" -n "${SI_NS}" scale deploy/banking-service --replicas=1
  oc --context "${FAIL_CLUSTER}" -n "${SI_NS}" scale deploy/api-gateway --replicas=1
  failover_ensure_quay_image "${FAIL_CLUSTER}" "${SI_NS}" banking-service
  failover_ensure_quay_image "${FAIL_CLUSTER}" "${SI_NS}" api-gateway

  local ok=0
  # Wait (and rewrite ImageStream→Quay if needed) BEFORE re-enabling Argo self-heal,
  # otherwise Argo can race us back to an unpullable local registry image.
  failover_wait_deploy "${FAIL_CLUSTER}" "${SI_NS}" banking-service 300 || true
  failover_wait_deploy "${FAIL_CLUSTER}" "${SI_NS}" api-gateway 180 || true
  failover_resume_argo "${FAIL_CLUSTER}" banking-si-service
  failover_resume_argo "${FAIL_CLUSTER}" banking-si-gateway

  if [[ "$(failover_replicas "${FAIL_CLUSTER}" "${SI_NS}" banking-service)" != "0" \
     && "$(failover_replicas "${FAIL_CLUSTER}" "${SI_NS}" api-gateway)" != "0" ]]; then
    ok=1
  fi

  local tok result code serving
  tok="$(failover_get_token "$(failover_keycloak_url)")"
  result="$(failover_call_customers "$(entry_url)" "${tok}")"
  code="${result%%|*}"
  serving="$(echo "${result}" | cut -d'|' -f2)"
  echo
  failover_print_route_check entry "${result}"
  printf '  %-5s svc=%s gw=%s\n' east \
    "$(failover_replicas east "${SI_NS}" banking-service)" \
    "$(failover_replicas east "${SI_NS}" api-gateway)"
  printf '  %-5s svc=%s gw=%s\n' west \
    "$(failover_replicas west "${SI_NS}" banking-service)" \
    "$(failover_replicas west "${SI_NS}" api-gateway)"
  if [[ "${ok}" -eq 1 && "${code}" =~ ^2 ]]; then
    echo "✓ Restored. Both sites should look healthy in Network Observer."
  else
    echo "⚠ Recover incomplete — check ImagePullBackOff / Quay pull secret (see messages above)."
    return 1
  fi
}

cmd_demo() {
  failover_banner "Live demo — what you will prove"
  failover_say "1) Service Interconnect: backend dies on ${FAIL_CLUSTER}, API still works via Skupper."
  failover_say "2) Ingress: ${FAIL_CLUSTER} Route dies → call the ${PEER_CLUSTER} OpenShift Route (no shared DNS)."
  failover_say "Entry: $(entry_url)"
  failover_legend
  failover_pause

  cmd_preflight
  failover_pause

  failover_banner "Step 1 — Open Network Observer (before traffic)"
  network_observer_guide
  "${SCRIPT_DIR}/si/console-url.sh" open 2>/dev/null || true
  failover_say "Log in now. Confirm Topology shows two linked sites. Then press Enter."
  failover_pause

  failover_banner "Step 2 — Baseline traffic (${ENTRY_CLUSTER} Route)"
  failover_say "Calling: $(entry_url)"
  failover_say "Log file: ${DETAIL_LOG}"
  failover_say "Leave Network Observer on Topology / banking-service while requests run."
  failover_legend
  failover_pause

  local base kc tid
  base="$(entry_url)"
  kc="$(failover_keycloak_url)"
  failover_say "Sending traffic for ~12s so Observer can scrape metrics…"
  failover_traffic_loop "baseline" "${base}" "${SI_NS}" "${kc}" &
  tid=$!
  trap 'kill ${tid} 2>/dev/null || true; echo' EXIT

  sleep 12
  echo
  failover_say "Traffic is running in the background. Glance at Network Observer, then press Enter for SI failover."
  failover_pause

  failover_banner "Step 3 — SI failover (backend)"
  kill "${tid}" 2>/dev/null || true
  wait "${tid}" 2>/dev/null || true
  trap - EXIT
  echo
  failover_say "Look at Network Observer NOW — this is the Skupper moment."
  NONINTERACTIVE=1 cmd_fail_backend
  failover_pause

  failover_banner "Step 4 — Ingress (peer OpenShift Route)"
  failover_say "Proof here is the terminal: ${FAIL_CLUSTER} Route fails, ${PEER_CLUSTER} Route stays API OK."
  NONINTERACTIVE=1 cmd_fail_ingress
  failover_pause

  failover_banner "Step 5 — Recover"
  NONINTERACTIVE=1 cmd_recover || true
  failover_banner "Demo complete"
  failover_say "Console: $(console_url)"
  failover_say "Entry:   $(entry_url)"
  failover_say "Log:     ${DETAIL_LOG}"
  echo
  failover_say "Mesh contrast (Kiali on ACM): ./scripts/demo-mesh-failover.sh"
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
