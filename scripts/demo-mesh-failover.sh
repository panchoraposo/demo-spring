#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# LIVE DEMO — OSSM ambient mesh failover via OpenShift Routes
# ═══════════════════════════════════════════════════════════════════════════
#
# Run:  ./scripts/demo-mesh-failover.sh
#
# Story:
#   Client → OpenShift Route on ENTRY_CLUSTER (east by default)
#        → api-gateway
#        → banking-service (ambient mesh can jump to the peer cluster)
#        → local PostgreSQL
#
# Failover shown:
#   A) MESH     — kill banking-service on east → ambient mesh serves west
#                 (still calling the east Route)
#   B) INGRESS  — kill api-gateway on east → east Route fails; west Route works
#
# Keep Kiali open on a second screen. Detail → .demo-failover.log
#
# Commands: demo | preflight | traffic | fail | fail-ingress | recover | status
# Env: SAMPLE_COUNT=8 SAMPLE_INTERVAL=0.4 BASELINE_SECONDS=5 INTERVAL=0.4
#═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

HUB_CONTEXT="${HUB_CONTEXT:-acm}"
FAIL_CLUSTER="${FAIL_CLUSTER:-east}"
ENTRY_CLUSTER="${ENTRY_CLUSTER:-east}"
PEER_CLUSTER="${PEER_CLUSTER:-}"
INTERVAL="${INTERVAL:-0.4}"
SAMPLE_COUNT="${SAMPLE_COUNT:-8}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-${INTERVAL}}"
BASELINE_SECONDS="${BASELINE_SECONDS:-5}"
BANKING_NS="${BANKING_NS:-banking-apps}"
DB_NS="${DB_NS:-banking-db}"
CLIENT_ID="${BANKING_CLIENT_ID:-banking-cli}"
BANKING_USER="${BANKING_USER:-teller}"
BANKING_PASSWORD="${BANKING_PASSWORD:-teller-change-me}"
DETAIL_LOG="${DETAIL_LOG:-$(pwd)/.demo-failover.log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/failover-demo.sh
source "${SCRIPT_DIR}/lib/failover-demo.sh"

if [[ -z "${PEER_CLUSTER}" ]]; then
  PEER_CLUSTER="$(failover_peer_of "${FAIL_CLUSTER}")"
fi

kiali_url() {
  local host
  host="$(oc --context "${HUB_CONTEXT}" -n istio-system get route kiali -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "${host}" ]] && echo "https://${host}"
}

entry_url() { failover_route_url "${ENTRY_CLUSTER}" "${BANKING_NS}"; }

ns_mesh_label() {
  local ctx="$1" ns="$2"
  oc --context "${ctx}" get ns "${ns}" \
    -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null || true
}

storyboard() {
  failover_banner "DEMO STORYBOARD — what we will prove"
  failover_say "Client calls the OpenShift Route on ${ENTRY_CLUSTER}:"
  failover_say "    $(entry_url)"
  echo
  failover_say "Each cluster (east/west) has its own Route → api-gateway → banking-service → Postgres."
  echo
  failover_say "Layer A — MESH failover"
  failover_say "    Scale banking-service on ${FAIL_CLUSTER} → 0."
  failover_say "    Keep calling the ${ENTRY_CLUSTER} Route; ambient mesh serves ${PEER_CLUSTER}."
  echo
  failover_say "Layer B — INGRESS (manual)"
  failover_say "    Scale api-gateway on ${FAIL_CLUSTER} → 0."
  failover_say "    ${FAIL_CLUSTER} Route fails; ${PEER_CLUSTER} Route still works (no shared DNS)."
  echo
  failover_say "Watch in parallel: Kiali graph (banking-apps) on the hub."
  failover_say "    $(kiali_url || echo '(Kiali URL unavailable)')"
  failover_say "Optional: Perses failover dashboard (Observe → Dashboards) — ./scripts/perses-url.sh"
  failover_legend
}

cmd_preflight() {
  failover_init_log "demo-mesh-failover"
  failover_banner "CHECK — is the demo ready?"
  local kiali ok=1
  kiali="$(kiali_url)"

  # AWS ELB hostnames must be resolved into Gateway status IPs so ambient
  # NetworkGateways / waypoint EW HBONE can reach the peer cluster.
  if [[ -x "${SCRIPT_DIR}/mesh/sync-eastwest-gateway-ips.sh" ]]; then
    failover_say "Syncing east-west gateway IPs into Gateway status…"
    "${SCRIPT_DIR}/mesh/sync-eastwest-gateway-ips.sh" || \
      failover_say "WARN: EW gateway IP sync failed — mesh failover may not work."
  fi

  failover_say "Entry Route (${ENTRY_CLUSTER}):  $(entry_url)"
  failover_say "Peer Route (${PEER_CLUSTER}):    $(failover_route_url "${PEER_CLUSTER}" "${BANKING_NS}")"
  failover_say "Kiali (second screen):           ${kiali:-MISSING}"
  echo

  local ctx mode
  for ctx in east west; do
    mode="$(ns_mesh_label "${ctx}" "${BANKING_NS}")"
    printf '  %-5s  mesh=%-8s  banking-service=%s  api-gateway=%s\n' \
      "${ctx}" "${mode:-unset}" \
      "$(failover_replicas "${ctx}" "${BANKING_NS}" banking-service)" \
      "$(failover_replicas "${ctx}" "${BANKING_NS}" api-gateway)"
    [[ "${mode}" == "ambient" ]] || ok=0
  done

  echo
  local tok result code serving rows
  failover_say "Calling the API once (JWT from hub Keycloak)…"
  tok="$(failover_get_token "$(failover_keycloak_url)")"
  [[ -n "${tok}" ]] || { echo "  FAIL: cannot get JWT" >&2; exit 1; }
  failover_seed_both_clusters "${BANKING_NS}" "${tok}"
  result="$(failover_call_customers "$(entry_url)" "${tok}")"
  code="${result%%|*}"
  serving="$(echo "${result}" | cut -d'|' -f2)"
  rows="$(echo "${result}" | cut -d'|' -f3)"
  failover_print_route_check "${ENTRY_CLUSTER}" "${result}" "$(entry_url)" "${BANKING_NS}"
  [[ "${code}" =~ ^2 ]] || { echo "  FAIL: API not healthy — see ${DETAIL_LOG}" >&2; exit 1; }
  if [[ "${rows}" == "0" ]]; then
    echo "  FAIL: customer list still empty after seed — check POST /api/v1/customers" >&2
    exit 1
  fi

  if [[ "${serving}" == "?" ]]; then
    failover_say "WARN: no X-Banking-Cluster header — watch svc e/w counts + Kiali."
  else
    failover_say "Serving cluster header is working (serving=${serving}, rows=${rows})."
  fi

  echo
  if [[ "${ok}" -eq 1 ]]; then
    failover_say "Ready for the live demo."
  else
    failover_say "WARN: ambient label missing on some namespaces — investigate after."
  fi
  failover_say "Detail log: ${DETAIL_LOG}"
}

cmd_status() {
  failover_banner "STATUS snapshot"
  failover_say "Entry: $(entry_url)"
  failover_say "Kiali: $(kiali_url)"
  local ctx
  for ctx in east west; do
    printf '  %-5s  banking-service=%s  api-gateway=%s  mesh=%s\n' "${ctx}" \
      "$(failover_replicas "${ctx}" "${BANKING_NS}" banking-service)" \
      "$(failover_replicas "${ctx}" "${BANKING_NS}" api-gateway)" \
      "$(ns_mesh_label "${ctx}" "${BANKING_NS}")"
  done
  local tok result
  tok="$(failover_get_token "$(failover_keycloak_url)")"
  result="$(failover_call_customers "$(entry_url)" "${tok}")"
  failover_print_route_check entry "${result}" "$(entry_url)" "${BANKING_NS}"
}

cmd_traffic() {
  failover_init_log "demo-mesh-failover"
  failover_banner "TRAFFIC — client calls the ${ENTRY_CLUSTER} OpenShift Route"
  failover_say "Open Kiali. Watch edges light up between api-gateway ↔ banking-service."
  failover_legend
  failover_traffic_loop "traffic" "$(entry_url)" "${BANKING_NS}" "$(failover_keycloak_url)"
}

cmd_fail() {
  failover_init_log "demo-mesh-failover"
  failover_banner "LAYER A — MESH FAILOVER"
  failover_say "Action:  scale banking-service on ${FAIL_CLUSTER} → 0 pods"
  failover_say "Expect:  ${ENTRY_CLUSTER} Route still API OK; serving→${PEER_CLUSTER}"
  failover_say "Watch:   Kiali — ${FAIL_CLUSTER} empty; traffic crosses to ${PEER_CLUSTER}"
  echo
  failover_say "Pausing ArgoCD self-heal on ${FAIL_CLUSTER}/banking-service…"
  failover_pause_argo "${FAIL_CLUSTER}" banking-service
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" scale deploy/banking-service --replicas=0
  echo
  failover_legend
  failover_say "Sampling ${ENTRY_CLUSTER} Route (${SAMPLE_COUNT} requests)…"
  echo
  failover_sample_window "mesh-failover" "$(entry_url)" "${BANKING_NS}" "${SAMPLE_COUNT}"
  echo
  local tok result code serving fail_r
  tok="$(failover_get_token "$(failover_keycloak_url)")"
  result="$(failover_call_customers "$(entry_url)" "${tok}")"
  code="${result%%|*}"
  serving="$(failover_infer_serving "$(echo "${result}" | cut -d'|' -f2)" "${code}" "${BANKING_NS}")"
  fail_r="$(failover_replicas "${FAIL_CLUSTER}" "${BANKING_NS}" banking-service)"
  if [[ "${code}" =~ ^2 ]] && [[ "${fail_r}" == "0" ]]; then
    echo "✓ Mesh kept the API up: gateway on ${ENTRY_CLUSTER}, backend on ${serving} (want ${PEER_CLUSTER})"
  else
    echo "⚠ Expected API OK via ${ENTRY_CLUSTER} with ${FAIL_CLUSTER} banking-service=0 (got HTTP ${code}, serving=${serving})"
  fi
}

cmd_fail_ingress() {
  failover_init_log "demo-mesh-failover"
  failover_banner "LAYER B — INGRESS (OpenShift Routes, no shared DNS)"
  failover_say "Action:  scale api-gateway on ${FAIL_CLUSTER} → 0 pods"
  failover_say "Expect:  ${FAIL_CLUSTER} Route fails; ${PEER_CLUSTER} Route still API OK"
  echo
  failover_pause_argo "${FAIL_CLUSTER}" api-gateway
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" scale deploy/api-gateway --replicas=0
  echo
  local tok result_fail result_peer
  tok="$(failover_get_token "$(failover_keycloak_url)")"
  failover_say "Calling both OpenShift Routes:"
  local url_fail url_peer
  url_fail="$(failover_route_url "${FAIL_CLUSTER}" "${BANKING_NS}")"
  url_peer="$(failover_route_url "${PEER_CLUSTER}" "${BANKING_NS}")"
  result_fail="$(failover_call_customers "${url_fail}" "${tok}")"
  failover_print_route_check "${FAIL_CLUSTER}" "${result_fail}" "${url_fail}" "${BANKING_NS}"
  result_peer="$(failover_call_customers "${url_peer}" "${tok}")"
  failover_print_route_check "${PEER_CLUSTER}" "${result_peer}" "${url_peer}" "${BANKING_NS}"
  echo
  if [[ ! "${result_fail%%|*}" =~ ^2 ]] && [[ "${result_peer%%|*}" =~ ^2 ]]; then
    echo "✓ Clients switch to the peer cluster Route when ${FAIL_CLUSTER} ingress is down."
  else
    echo "⚠ Unexpected results — check Routes and api-gateway pods."
  fi
}

cmd_recover() {
  failover_banner "RECOVER — bring ${FAIL_CLUSTER} back"
  failover_say "Scaling banking-service and api-gateway back to 1…"
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" scale deploy/banking-service --replicas=1
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" scale deploy/api-gateway --replicas=1
  failover_ensure_quay_image "${FAIL_CLUSTER}" "${BANKING_NS}" banking-service
  failover_ensure_quay_image "${FAIL_CLUSTER}" "${BANKING_NS}" api-gateway

  local ok=0
  # Wait before re-enabling Argo so self-heal cannot race a bad image rewrite.
  failover_wait_deploy "${FAIL_CLUSTER}" "${BANKING_NS}" banking-service 300 || true
  failover_wait_deploy "${FAIL_CLUSTER}" "${BANKING_NS}" api-gateway 180 || true
  failover_resume_argo "${FAIL_CLUSTER}" banking-service
  failover_resume_argo "${FAIL_CLUSTER}" api-gateway
  if [[ "$(failover_replicas "${FAIL_CLUSTER}" "${BANKING_NS}" banking-service)" != "0" \
     && "$(failover_replicas "${FAIL_CLUSTER}" "${BANKING_NS}" api-gateway)" != "0" ]]; then
    ok=1
  fi

  local tok result code
  tok="$(failover_get_token "$(failover_keycloak_url)")"
  result="$(failover_call_customers "$(entry_url)" "${tok}")"
  code="${result%%|*}"
  echo
  failover_print_route_check entry "${result}" "$(entry_url)" "${BANKING_NS}"
  printf '  %-5s svc=%s gw=%s\n' east \
    "$(failover_replicas east "${BANKING_NS}" banking-service)" \
    "$(failover_replicas east "${BANKING_NS}" api-gateway)"
  printf '  %-5s svc=%s gw=%s\n' west \
    "$(failover_replicas west "${BANKING_NS}" banking-service)" \
    "$(failover_replicas west "${BANKING_NS}" api-gateway)"
  if [[ "${ok}" -eq 1 && "${code}" =~ ^2 ]]; then
    echo "✓ Restored. Both clusters should look healthy again in Kiali."
  else
    echo "⚠ Recover incomplete — check pods / pull secrets (see messages above)."
    return 1
  fi
}

cmd_demo() {
  storyboard
  failover_pause

  echo
  echo "┌─ STEP 1/5 ─────────────────────────────────────────────────"
  echo "│  Preflight — confirm Routes, mesh, and API are healthy"
  echo "└──────────────────────────────────────────────────────────"
  NONINTERACTIVE=1 cmd_preflight
  failover_pause

  echo
  echo "┌─ STEP 2/5 ─────────────────────────────────────────────────"
  echo "│  Open Kiali (second screen) — graph for banking-apps"
  echo "└──────────────────────────────────────────────────────────"
  failover_say "URL: $(kiali_url)"
  failover_say "Tip: add banking-db to see mTLS edges to Postgres."
  failover_pause

  echo
  echo "┌─ STEP 3/5 ─────────────────────────────────────────────────"
  echo "│  Generate live traffic against the ${ENTRY_CLUSTER} Route"
  echo "└──────────────────────────────────────────────────────────"
  failover_say "Audience talking point: mesh can move backend work across clusters."
  failover_legend
  local gw kc tid
  gw="$(entry_url)"
  kc="$(failover_keycloak_url)"
  failover_traffic_loop "baseline" "${gw}" "${BANKING_NS}" "${kc}" &
  tid=$!
  trap 'kill ${tid} 2>/dev/null || true; echo' EXIT
  sleep "${BASELINE_SECONDS}"
  echo
  echo
  failover_say "Baseline traffic is running. Next we break ${FAIL_CLUSTER}."
  failover_pause

  echo
  echo "┌─ STEP 4/5 ─────────────────────────────────────────────────"
  echo "│  MESH failover — kill banking-service on ${FAIL_CLUSTER}"
  echo "└──────────────────────────────────────────────────────────"
  kill "${tid}" 2>/dev/null || true
  wait "${tid}" 2>/dev/null || true
  trap - EXIT
  echo
  NONINTERACTIVE=1 cmd_fail
  failover_pause

  echo
  echo "┌─ STEP 5/5 ─────────────────────────────────────────────────"
  echo "│  INGRESS — kill api-gateway; use ${PEER_CLUSTER} Route"
  echo "└──────────────────────────────────────────────────────────"
  NONINTERACTIVE=1 cmd_fail_ingress
  failover_pause

  failover_banner "WRAP-UP"
  NONINTERACTIVE=1 cmd_recover || true
  echo
  failover_say "Recap for the audience:"
  failover_say "  • Entry via OpenShift Route on ${ENTRY_CLUSTER}: $(entry_url)"
  failover_say "  • Mesh kept the API up when ${FAIL_CLUSTER} banking-service died"
  failover_say "  • When ${FAIL_CLUSTER} ingress died, clients use the ${PEER_CLUSTER} Route"
  failover_say "  • Kiali: $(kiali_url)"
  failover_say "  • Log:   ${DETAIL_LOG}"
}

case "${1:-demo}" in
  preflight)    cmd_preflight ;;
  traffic)      cmd_traffic ;;
  fail)         cmd_fail ;;
  fail-dns|fail-ingress) cmd_fail_ingress ;;
  recover)      cmd_recover ;;
  status)       cmd_status ;;
  demo)         cmd_demo ;;
  *)
    echo "Usage: $0 {demo|preflight|traffic|fail|fail-ingress|recover|status}" >&2
    echo "  demo          interactive live demo (default)" >&2
    echo "  preflight     readiness check only" >&2
    echo "  fail-ingress  show peer Route after entry gateway is drained" >&2
    exit 1
    ;;
esac
