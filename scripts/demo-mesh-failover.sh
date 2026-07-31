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
#═══════════════════════════════════════════════════════════════════════════
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

say() { printf '  %s\n' "$*"; }

pause() {
  if [[ -t 0 && "${NONINTERACTIVE:-0}" != "1" ]]; then
    echo
    read -r -p "▶  Press Enter for next step… " _
  fi
}

banner() {
  echo
  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
  printf '┃ %-58s ┃\n' "$*"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
}

step() {
  echo
  echo "┌─ STEP $1 ─────────────────────────────────────────────────"
  echo "│  $2"
  echo "└──────────────────────────────────────────────────────────"
}

detail() { printf '%s\n' "$*" >> "${DETAIL_LOG}"; }

legend() {
  echo
  say "Status line legend:"
  say "  HTTP        → client still gets 200 (good) or error (bad)"
  say "  serving=…   → which cluster handled banking-service (X-Banking-Cluster)"
  say "  east/west   → readyReplicas of banking-service on each cluster"
  echo
}

kiali_url() {
  local host
  host="$(oc --context "${HUB_CONTEXT}" -n istio-system get route kiali -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "${host}" ]] && echo "https://${host}"
}

cluster_route_url() {
  local ctx="$1"
  echo "https://$(oc --context "${ctx}" -n "${BANKING_NS}" get route api-gateway -o jsonpath='{.spec.host}')"
}

entry_url() { cluster_route_url "${ENTRY_CLUSTER}"; }

keycloak_url() {
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
  local ctx="$1" deploy="${2:-banking-service}" r
  r="$(oc --context "${ctx}" -n "${BANKING_NS}" get deploy "${deploy}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  echo "${r:-0}"
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

# Returns: code|cluster|customers|snippet
call_customers() {
  local gw="$1" token="$2"
  local hdrs body code cluster bytes snippet count
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
  detail "HTTP ${code}  serving=${cluster}  customers=${count}  bytes=${bytes}"
  detail "body: ${snippet}"
  rm -f "${hdrs}" "${body}"
  printf '%s|%s|%s|%s\n' "${code}" "${cluster}" "${count}" "${snippet}"
}

show_line() {
  local code="$1" serving="$2" customers="$3" phase="$4"
  local east_r west_r mark
  east_r="$(replicas east)"
  west_r="$(replicas west)"
  if [[ "${code}" =~ ^2 ]]; then mark="OK "; else mark="ERR"; fi
  printf '\r\033[K  %s │ %-18s │ HTTP %s │ serving=%-5s │ customers=%-3s │ east pods=%s  west pods=%s' \
    "$(date +%H:%M:%S)" "${phase}" "${mark} ${code}" "${serving}" "${customers}" \
    "${east_r:-0}" "${west_r:-0}"
}

pause_argo() {
  local ctx="$1" app="$2"
  oc --context "${ctx}" -n openshift-gitops patch applications.argoproj.io "${app}" \
    --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null 2>&1 || true
}

resume_argo() {
  local ctx="$1" app="$2"
  oc --context "${ctx}" -n openshift-gitops patch applications.argoproj.io "${app}" \
    --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null 2>&1 || true
}

init_log() {
  mkdir -p "$(dirname "${DETAIL_LOG}")"
  : > "${DETAIL_LOG}"
  detail "demo-mesh-failover $(date -u +%Y-%m-%dT%H:%M:%SZ) fail=${FAIL_CLUSTER} peer=${PEER_CLUSTER}"
}

storyboard() {
  banner "DEMO STORYBOARD — what we will prove"
  say "Client calls the OpenShift Route on ${ENTRY_CLUSTER}:"
  say "    $(entry_url)"
  echo
  say "Each cluster (east/west) has its own Route → api-gateway → banking-service → Postgres."
  echo
  say "Layer A — MESH failover"
  say "    Scale banking-service on ${FAIL_CLUSTER} → 0."
  say "    Keep calling the ${ENTRY_CLUSTER} Route; ambient mesh serves ${PEER_CLUSTER}."
  echo
  say "Layer B — INGRESS (manual)"
  say "    Scale api-gateway on ${FAIL_CLUSTER} → 0."
  say "    ${FAIL_CLUSTER} Route fails; ${PEER_CLUSTER} Route still works (no shared DNS)."
  echo
  say "Watch in parallel: Kiali graph (banking-apps) on the hub."
  say "    $(kiali_url || echo '(Kiali URL unavailable)')"
}

cmd_preflight() {
  init_log
  banner "CHECK — is the demo ready?"
  local kiali ok=1
  kiali="$(kiali_url)"

  say "Entry Route (${ENTRY_CLUSTER}):  $(entry_url)"
  say "Peer Route (${PEER_CLUSTER}):    $(cluster_route_url "${PEER_CLUSTER}")"
  say "Kiali (second screen):           ${kiali:-MISSING}"
  echo

  local ctx mode
  for ctx in east west; do
    mode="$(ns_mesh_label "${ctx}" "${BANKING_NS}")"
    printf '  %-5s  mesh=%-8s  banking-service=%s  api-gateway=%s  route=%s\n' \
      "${ctx}" "${mode:-unset}" "$(replicas "${ctx}")" "$(replicas "${ctx}" api-gateway)" \
      "$(cluster_route_url "${ctx}")"
    [[ "${mode}" == "ambient" ]] || ok=0
  done

  echo
  local tok result code serving
  say "Calling the API once (JWT from hub Keycloak)…"
  tok="$(get_token "$(keycloak_url)")"
  [[ -n "${tok}" ]] || { echo "  FAIL: cannot get JWT" >&2; exit 1; }
  result="$(call_customers "$(entry_url)" "${tok}")"
  code="${result%%|*}"
  serving="$(echo "${result}" | cut -d'|' -f2)"
  say "Result: HTTP ${code}   served by cluster: ${serving}"
  [[ "${code}" =~ ^2 ]] || { echo "  FAIL: API not healthy — see ${DETAIL_LOG}" >&2; exit 1; }

  if [[ "${serving}" == "?" ]]; then
    echo
    say "Note: 'serving=?' means the image does not yet return X-Banking-Cluster."
    say "      For the story, watch east/west pod counts + Kiali instead."
  fi

  echo
  if [[ "${ok}" -eq 1 ]]; then
    say "Ready for the live demo."
  else
    say "WARN: ambient label missing on some namespaces — investigate after."
  fi
  say "Detail log: ${DETAIL_LOG}"
}

cmd_status() {
  banner "STATUS snapshot"
  say "Entry: $(entry_url)"
  say "Kiali: $(kiali_url)"
  for ctx in east west; do
    printf '  %-5s  banking-service=%s  api-gateway=%s  mesh=%s\n' "${ctx}" \
      "$(replicas "${ctx}" banking-service)" \
      "$(replicas "${ctx}" api-gateway)" \
      "$(ns_mesh_label "${ctx}" "${BANKING_NS}")"
  done
  local tok result
  tok="$(get_token "$(keycloak_url)")"
  result="$(call_customers "$(entry_url)" "${tok}")"
  say "API: HTTP ${result%%|*}  serving=$(echo "${result}" | cut -d'|' -f2)"
}

traffic_loop() {
  local phase="$1" gw="$2" kc="$3"
  local tok result code serving customers ok=0 fail=0
  tok="$(get_token "${kc}")"
  [[ -n "${tok}" ]] || { say "no token"; return 1; }
  say "Sending GET ${gw}/api/v1/customers every ${INTERVAL}s  (CTRL+C to stop)"
  legend
  while true; do
    result="$(call_customers "${gw}" "${tok}")"
    code="${result%%|*}"
    serving="$(echo "${result}" | cut -d'|' -f2)"
    customers="$(echo "${result}" | cut -d'|' -f3)"
    if [[ "${code}" =~ ^2 ]]; then
      ok=$((ok + 1))
      show_line "${code}" "${serving}" "${customers}" "${phase} #${ok}"
    else
      fail=$((fail + 1))
      show_line "${code}" "${serving}" "${customers}" "${phase} FAIL#${fail}"
      [[ "${code}" == "401" || "${code}" == "403" ]] && tok="$(get_token "${kc}")"
    fi
    sleep "${INTERVAL}"
  done
}

cmd_traffic() {
  init_log
  banner "TRAFFIC — client calls the ${ENTRY_CLUSTER} OpenShift Route"
  say "Open Kiali. Watch edges light up between api-gateway ↔ banking-service."
  echo
  traffic_loop "traffic" "$(entry_url)" "$(keycloak_url)"
}

sample_window() {
  local phase="$1" gw="$2" n="${3:-25}"
  local kc tok result code serving customers ok=0 fail=0 i last="?"
  kc="$(keycloak_url)"
  tok="$(get_token "${kc}")"
  legend
  for i in $(seq 1 "${n}"); do
    result="$(call_customers "${gw}" "${tok}")"
    code="${result%%|*}"
    serving="$(echo "${result}" | cut -d'|' -f2)"
    customers="$(echo "${result}" | cut -d'|' -f3)"
    last="${serving}"
    if [[ "${code}" =~ ^2 ]]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    show_line "${code}" "${serving}" "${customers}" "${phase} ${i}/${n}"
    sleep 1
  done
  echo
  echo
  say "Window result: ${ok} OK / ${fail} errors   last serving=${last}"
}

cmd_fail() {
  init_log
  banner "LAYER A — MESH FAILOVER"
  say "Action:  scale banking-service on ${FAIL_CLUSTER} → 0 pods"
  say "Expect:  ${ENTRY_CLUSTER} Route still HTTP 200 (mesh routes to ${PEER_CLUSTER})"
  say "Watch:   Kiali — ${FAIL_CLUSTER} banking-service empty; traffic crosses to ${PEER_CLUSTER}"
  echo
  say "Pausing ArgoCD self-heal on ${FAIL_CLUSTER}/banking-service…"
  pause_argo "${FAIL_CLUSTER}" banking-service
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" scale deploy/banking-service --replicas=0
  echo
  say "Sampling ${ENTRY_CLUSTER} Route for ~25s…"
  sample_window "mesh-failover" "$(entry_url)" 25
  echo
  if [[ "$(replicas "${FAIL_CLUSTER}")" == "0" || "$(replicas "${FAIL_CLUSTER}")" == "" ]]; then
    say "${FAIL_CLUSTER} banking-service pods = 0"
  fi
  say "If HTTP stayed OK while ${FAIL_CLUSTER} pods hit 0 → that is ambient mesh failover."
}

cmd_fail_ingress() {
  init_log
  banner "LAYER B — INGRESS (OpenShift Routes, no shared DNS)"
  say "Action:  scale api-gateway on ${FAIL_CLUSTER} → 0 pods"
  say "Expect:  ${FAIL_CLUSTER} Route fails; ${PEER_CLUSTER} Route still HTTP 200"
  echo
  pause_argo "${FAIL_CLUSTER}" api-gateway
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" scale deploy/api-gateway --replicas=0
  echo
  local tok result_fail result_peer
  tok="$(get_token "$(keycloak_url)")"
  say "Calling ${FAIL_CLUSTER} Route (should fail)…"
  result_fail="$(call_customers "$(cluster_route_url "${FAIL_CLUSTER}")" "${tok}")"
  say "  ${FAIL_CLUSTER}: HTTP ${result_fail%%|*}"
  say "Calling ${PEER_CLUSTER} Route (should work)…"
  result_peer="$(call_customers "$(cluster_route_url "${PEER_CLUSTER}")" "${tok}")"
  say "  ${PEER_CLUSTER}: HTTP ${result_peer%%|*}  serving=$(echo "${result_peer}" | cut -d'|' -f2)"
  echo
  if [[ ! "${result_fail%%|*}" =~ ^2 ]] && [[ "${result_peer%%|*}" =~ ^2 ]]; then
    say "✓ Clients switch to the peer cluster Route when ${FAIL_CLUSTER} ingress is down."
  else
    say "⚠ Unexpected results — check Routes and api-gateway pods."
  fi
}

cmd_recover() {
  banner "RECOVER — bring ${FAIL_CLUSTER} back"
  say "Scaling banking-service and api-gateway back to 1…"
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" scale deploy/banking-service --replicas=1
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" scale deploy/api-gateway --replicas=1
  resume_argo "${FAIL_CLUSTER}" banking-service
  resume_argo "${FAIL_CLUSTER}" api-gateway
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" rollout status deploy/banking-service --timeout=180s
  oc --context "${FAIL_CLUSTER}" -n "${BANKING_NS}" rollout status deploy/api-gateway --timeout=180s
  local tok result
  tok="$(get_token "$(keycloak_url)")"
  result="$(call_customers "$(entry_url)" "${tok}")"
  echo
  say "API after recover: HTTP ${result%%|*}  serving=$(echo "${result}" | cut -d'|' -f2)"
  say "Both clusters should look healthy again in Kiali."
}

cmd_demo() {
  storyboard
  pause

  step "1/5" "Preflight — confirm Routes, mesh, and API are healthy"
  NONINTERACTIVE=1 cmd_preflight
  pause

  step "2/5" "Open Kiali (second screen) — graph for banking-apps, clusters east+west"
  say "URL: $(kiali_url)"
  say "Tip: add banking-db to see mTLS edges to Postgres."
  pause

  step "3/5" "Generate live traffic against the ${ENTRY_CLUSTER} Route"
  say "Audience talking point: mesh can move backend work across clusters."
  legend
  local gw kc tid
  gw="$(entry_url)"
  kc="$(keycloak_url)"
  traffic_loop "baseline" "${gw}" "${kc}" &
  tid=$!
  trap 'kill ${tid} 2>/dev/null || true; echo' EXIT
  sleep 10
  echo
  echo
  say "Baseline traffic is running. Next we break ${FAIL_CLUSTER}."
  pause

  step "4/5" "MESH failover — kill banking-service on ${FAIL_CLUSTER}"
  kill "${tid}" 2>/dev/null || true
  wait "${tid}" 2>/dev/null || true
  trap - EXIT
  echo
  NONINTERACTIVE=1 cmd_fail
  pause

  step "5/5" "INGRESS — kill api-gateway on ${FAIL_CLUSTER}; use ${PEER_CLUSTER} Route"
  NONINTERACTIVE=1 cmd_fail_ingress
  pause

  banner "WRAP-UP"
  NONINTERACTIVE=1 cmd_recover
  echo
  say "Recap for the audience:"
  say "  • Entry via OpenShift Route on ${ENTRY_CLUSTER}: $(entry_url)"
  say "  • Mesh kept the API up when ${FAIL_CLUSTER} banking-service died"
  say "  • When ${FAIL_CLUSTER} ingress died, clients use the ${PEER_CLUSTER} Route"
  say "  • Kiali: $(kiali_url)"
  say "  • Log:   ${DETAIL_LOG}"
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
