#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# DEMO — Custom Metrics Autoscaler (KEDA) scale-out for Spring apps
# ═══════════════════════════════════════════════════════════════════════════
#
# Run:  ./scripts/demo-keda-scale.sh
#
# Story:
#   Generate HTTP load against the OpenShift Route → api-gateway → banking-service.
#   CMA ScaledObjects (CPU + Prometheus HTTP RPS) raise replicas toward max 10.
#   After load stops, cooldown scales back toward minReplicaCount (1).
#
# Commands: demo | preflight | load | status | watch
# Env: CLUSTER=east BANKING_NS=banking-apps LOAD_SECONDS=120 CONCURRENCY=40
#═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

HUB_CONTEXT="${HUB_CONTEXT:-acm}"
CLUSTER="${CLUSTER:-east}"
BANKING_NS="${BANKING_NS:-banking-apps}"
LOAD_SECONDS="${LOAD_SECONDS:-120}"
CONCURRENCY="${CONCURRENCY:-40}"
CLIENT_ID="${BANKING_CLIENT_ID:-banking-cli}"
BANKING_USER="${BANKING_USER:-teller}"
BANKING_PASSWORD="${BANKING_PASSWORD:-teller-change-me}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/failover-demo.sh
source "${SCRIPT_DIR}/lib/failover-demo.sh"

say() { failover_say "$@"; }
banner() { failover_banner "$@"; }

route_url() {
  failover_route_url "${CLUSTER}" "${BANKING_NS}"
}

get_token() {
  failover_get_token
}

replicas_of() {
  failover_replicas "${CLUSTER}" "${BANKING_NS}" "$1"
}

show_status() {
  banner "STATUS — ${CLUSTER} / ${BANKING_NS}"
  say "Route: $(route_url)"
  echo
  oc --context "${CLUSTER}" -n "${BANKING_NS}" get scaledobject,hpa 2>/dev/null || true
  echo
  oc --context "${CLUSTER}" -n "${BANKING_NS}" get deploy,pods \
    -l 'app.kubernetes.io/name in (api-gateway,banking-service)' \
    -o wide 2>/dev/null || true
  echo
  say "api-gateway ready: $(replicas_of api-gateway)   banking-service ready: $(replicas_of banking-service)"
}

preflight() {
  banner "PREFLIGHT"
  failover_need oc
  failover_need curl
  failover_need jq
  if ! command -v hey >/dev/null 2>&1 && ! command -v ab >/dev/null 2>&1; then
    echo "missing load tool: install 'hey' (preferred) or Apache Bench 'ab'" >&2
    exit 1
  fi

  oc --context "${CLUSTER}" -n openshift-keda get kedacontroller keda >/dev/null
  oc --context "${CLUSTER}" -n "${BANKING_NS}" get scaledobject api-gateway banking-service >/dev/null
  oc --context "${CLUSTER}" -n "${BANKING_NS}" get triggerauthentication keda-prom-auth >/dev/null

  local token url
  token="$(get_token)"
  [[ -n "${token}" && "${token}" != "null" ]] || { echo "failed to get Keycloak token" >&2; exit 1; }
  url="$(route_url)"
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    "${url}/api/v1/customers" || echo 000)"
  [[ "${code}" == "200" ]] || { echo "baseline GET /api/v1/customers → HTTP ${code}" >&2; exit 1; }
  say "OK — CMA present, ScaledObjects ready, Route returns 200"
  show_status
}

run_load() {
  local token url
  token="$(get_token)"
  url="$(route_url)"
  local target="${url}/api/v1/customers"

  banner "LOAD — ${CONCURRENCY} concurrent for ${LOAD_SECONDS}s"
  say "Target: ${target}"
  say "Watch: oc --context ${CLUSTER} -n ${BANKING_NS} get scaledobject,hpa,pods -w"
  echo

  if command -v hey >/dev/null 2>&1; then
    hey -z "${LOAD_SECONDS}s" -c "${CONCURRENCY}" \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/json" \
      "${target}"
  else
    # ab uses total requests; approximate duration with a large -n.
    local n=$(( CONCURRENCY * LOAD_SECONDS * 5 ))
    ab -n "${n}" -c "${CONCURRENCY}" -s 30 \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/json" \
      "${target}/" 2>&1 || true
  fi
}

watch_scale() {
  banner "WATCH — ScaledObject / HPA / pods (Ctrl-C to stop)"
  oc --context "${CLUSTER}" -n "${BANKING_NS}" get scaledobject,hpa,pods \
    -l 'app.kubernetes.io/name in (api-gateway,banking-service)' \
    -w
}

demo() {
  banner "DEMO STORYBOARD — CMA metric-based scale-out"
  say "1. Baseline: Spring apps at minReplicaCount (1)."
  say "2. Generate HTTP load → Prometheus http_server_requests_* rises; CPU rises."
  say "3. ScaledObjects drive HPA toward maxReplicaCount (10)."
  say "4. Stop load → cooldownPeriod (60s) scales back toward 1."
  echo
  say "Cluster=${CLUSTER}  namespace=${BANKING_NS}"
  say "Detail: docs/keda-autoscaling.md"
  failover_pause

  preflight
  failover_pause

  banner "BASELINE"
  show_status
  failover_pause

  # Status sampler in background while load runs.
  (
    for _ in $(seq 1 "$(( LOAD_SECONDS / 10 + 2 ))"); do
      sleep 10
      printf '\n--- %s replicas gw=%s svc=%s ---\n' \
        "$(date +%H:%M:%S)" \
        "$(replicas_of api-gateway)" \
        "$(replicas_of banking-service)"
    done
  ) &
  local sampler_pid=$!

  run_load || true
  kill "${sampler_pid}" 2>/dev/null || true
  wait "${sampler_pid}" 2>/dev/null || true

  banner "AFTER LOAD"
  show_status
  say "Leave idle ~60–120s to observe scale-in (cooldownPeriod=60)."
  failover_pause
  show_status
  banner "DONE"
}

usage() {
  cat <<EOF
Usage: $0 [demo|preflight|load|status|watch]

  demo        Full interactive demo (default)
  preflight   Check CMA, ScaledObjects, Route
  load        Generate HTTP load only
  status      Show ScaledObject / HPA / pods
  watch       oc get … -w

Env: CLUSTER BANKING_NS LOAD_SECONDS CONCURRENCY HUB_CONTEXT
EOF
}

cmd="${1:-demo}"
case "${cmd}" in
  demo) demo ;;
  preflight) preflight ;;
  load) run_load ;;
  status) show_status ;;
  watch) watch_scale ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
