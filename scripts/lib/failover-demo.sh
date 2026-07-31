# Shared helpers for mesh + Service Interconnect failover demos.
# shellcheck shell=bash
# Sourced by scripts/demo-*-failover.sh — do not execute directly.

failover_need() {
  command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }
}

failover_need oc
failover_need curl
failover_need jq

failover_say() { printf '  %s\n' "$*"; }

failover_banner() {
  echo
  echo "════════════════════════════════════════════════════════"
  echo " $*"
  echo "════════════════════════════════════════════════════════"
}

failover_pause() {
  if [[ -t 0 && "${NONINTERACTIVE:-0}" != "1" ]]; then
    echo
    read -r -p "▶ Press Enter to continue… " _
  fi
}

failover_detail() {
  [[ -n "${DETAIL_LOG:-}" ]] || return 0
  printf '%s\n' "$*" >> "${DETAIL_LOG}"
}

failover_init_log() {
  local label="${1:-failover-demo}"
  DETAIL_LOG="${DETAIL_LOG:-$(pwd)/.demo-failover.log}"
  mkdir -p "$(dirname "${DETAIL_LOG}")"
  : > "${DETAIL_LOG}"
  failover_detail "${label} started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  failover_detail "fail=${FAIL_CLUSTER:-?} peer=${PEER_CLUSTER:-?} entry=${ENTRY_CLUSTER:-?} ns=${BANKING_NS:-?}"
}

failover_legend() {
  cat <<'EOF'

Status line (what the audience should watch):
  API          → OK 200 = request succeeded | FAIL xxx = client saw an error
  serving      → which cluster ran banking-service (X-Banking-Cluster: east|west)
                 "~west" means header missing; inferred from pod counts
  rows         → customer records returned (0 is fine if that cluster DB is empty)
  svc e/w      → banking-service readyReplicas on east / west  (backend story)
  gw  e/w      → api-gateway readyReplicas on east / west      (ingress story)

Full request dumps → detail log file (not this line).

EOF
}

failover_peer_of() {
  if [[ "$1" == "east" ]]; then echo west; else echo east; fi
}

failover_replicas() {
  local ctx="$1" ns="$2" deploy="$3" r
  r="$(oc --context "${ctx}" -n "${ns}" get deploy "${deploy}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  echo "${r:-0}"
}

failover_keycloak_url() {
  if [[ -n "${KEYCLOAK_URL:-}" ]]; then
    echo "${KEYCLOAK_URL}"
    return
  fi
  local host
  host="$(oc --context "${HUB_CONTEXT:-acm}" -n banking-idp get route sso \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  echo "https://${host}"
}

failover_get_token() {
  local kc="${1:-$(failover_keycloak_url)}"
  curl -sk -X POST "${kc}/realms/banking/protocol/openid-connect/token" \
    -d "client_id=${CLIENT_ID:-banking-cli}" \
    -d "username=${BANKING_USER:-teller}" \
    -d "password=${BANKING_PASSWORD:-teller-change-me}" \
    -d "grant_type=password" | jq -r '.access_token // empty'
}

failover_route_url() {
  local ctx="$1" ns="$2"
  echo "https://$(oc --context "${ctx}" -n "${ns}" get route api-gateway -o jsonpath='{.spec.host}')"
}

# Returns: code|serving|rows|snippet
# serving is the X-Banking-Cluster header, or "?" if absent.
failover_call_customers() {
  local base="$1" token="$2"
  local hdrs body code cluster bytes snippet rows
  hdrs="$(mktemp)"
  body="$(mktemp)"
  code="$(curl -sk -D "${hdrs}" -o "${body}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json" \
    "${base}/api/v1/customers" || echo 000)"
  # Portable parse (macOS awk has no IGNORECASE); strip CR from HTTP/1.1 headers.
  cluster="$(grep -i '^x-banking-cluster:' "${hdrs}" 2>/dev/null | head -1 \
    | tr -d '\r' | sed -E 's/^[^:]+:[[:space:]]*//')"
  [[ -n "${cluster}" ]] || cluster="?"
  bytes="$(wc -c < "${body}" | tr -d ' ')"
  snippet="$(head -c 160 "${body}" | tr '\n' ' ')"
  rows="$(jq -r 'if type=="array" then length else "?" end' "${body}" 2>/dev/null || echo "?")"
  failover_detail "---- $(date -u +%Y-%m-%dT%H:%M:%SZ) GET ${base}/api/v1/customers"
  failover_detail "HTTP ${code}  serving=${cluster}  rows=${rows}  bytes=${bytes}"
  failover_detail "body: ${snippet}"
  rm -f "${hdrs}" "${body}"
  printf '%s|%s|%s|%s\n' "${code}" "${cluster}" "${rows}" "${snippet}"
}

# When the response header is missing, infer serving cluster from replica counts
# during a backend drain (fail cluster at 0, peer still up, HTTP OK).
failover_infer_serving() {
  local header="$1" code="$2" ns="$3" fail="${FAIL_CLUSTER:-east}" peer="${PEER_CLUSTER:-west}"
  local fail_r peer_r
  if [[ "${header}" != "?" && -n "${header}" ]]; then
    echo "${header}"
    return
  fi
  if [[ ! "${code}" =~ ^2 ]]; then
    echo "?"
    return
  fi
  fail_r="$(failover_replicas "${fail}" "${ns}" banking-service)"
  peer_r="$(failover_replicas "${peer}" "${ns}" banking-service)"
  if [[ "${fail_r}" == "0" && "${peer_r}" != "0" ]]; then
    echo "~${peer}"
    return
  fi
  if [[ "${fail_r}" != "0" && "${peer_r}" == "0" ]]; then
    echo "~${fail}"
    return
  fi
  echo "?"
}

failover_show_line() {
  local code="$1" serving="$2" rows="$3" phase="$4" ns="$5"
  local east_svc west_svc east_gw west_gw mark
  east_svc="$(failover_replicas east "${ns}" banking-service)"
  west_svc="$(failover_replicas west "${ns}" banking-service)"
  east_gw="$(failover_replicas east "${ns}" api-gateway)"
  west_gw="$(failover_replicas west "${ns}" api-gateway)"
  if [[ "${code}" =~ ^2 ]]; then mark="OK "; else mark="FAIL"; fi
  printf '\r\033[K[%s] %-14s  API %s %-3s  serving=%-5s  rows=%-3s  svc e/w=%s/%s  gw e/w=%s/%s' \
    "$(date +%H:%M:%S)" "${phase}" "${mark}" "${code}" "${serving}" "${rows}" \
    "${east_svc}" "${west_svc}" "${east_gw}" "${west_gw}"
}

failover_pause_argo() {
  local ctx="$1" app="$2"
  oc --context "${ctx}" -n openshift-gitops patch "applications.argoproj.io/${app}" \
    --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null 2>&1 || true
}

failover_resume_argo() {
  local ctx="$1" app="$2"
  oc --context "${ctx}" -n openshift-gitops patch "applications.argoproj.io/${app}" \
    --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null 2>&1 || true
}

failover_pod_problems() {
  local ctx="$1" ns="$2" deploy="$3"
  oc --context "${ctx}" -n "${ns}" get pods -l "app.kubernetes.io/name=${deploy}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{range .status.containerStatuses[*]}{.state.waiting.reason}{.state.terminated.reason}{end}{"\n"}{end}' \
    2>/dev/null || true
}

# Prefer a pullable Quay image when OpenShift ImageStream local lookup / cross-ns
# pulls leave pods in ImagePullBackOff (common after SI recover).
failover_quay_image_for() {
  local deploy="$1"
  local registry="${QUAY_REGISTRY:-banking-quay-quay-quay-enterprise.apps.cluster-k7kqp.k7kqp.sandbox3321.opentlc.com}"
  local tag="${BANKING_IMAGE_TAG:-29}"
  case "${deploy}" in
    banking-service|api-gateway) echo "${registry}/banking/${deploy}:${tag}" ;;
    *) echo "" ;;
  esac
}

failover_ensure_quay_image() {
  local ctx="$1" ns="$2" deploy="$3"
  local current desired quay problems
  current="$(oc --context "${ctx}" -n "${ns}" get deploy "${deploy}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  desired="$(oc --context "${ctx}" -n "${ns}" get deploy "${deploy}" \
    -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' 2>/dev/null \
    | jq -r '.spec.template.spec.containers[0].image // empty' 2>/dev/null || true)"
  quay="$(failover_quay_image_for "${deploy}")"

  # Prefer last-applied when it already points at Quay (or any non-local registry).
  if [[ -n "${desired}" && "${desired}" != image-registry.openshift-image-registry.svc:5000/* ]]; then
    :
  elif [[ -n "${quay}" ]]; then
    desired="${quay}"
  else
    return 0
  fi

  problems="$(failover_pod_problems "${ctx}" "${ns}" "${deploy}")"
  if [[ "${current}" == "${desired}" ]] && ! echo "${problems}" | grep -qE 'ImagePullBackOff|ErrImagePull'; then
    return 0
  fi

  # Rewrite when current is in-cluster registry, or pods cannot pull the current image.
  if [[ "${current}" == image-registry.openshift-image-registry.svc:5000/* ]] \
     || echo "${problems}" | grep -qE 'ImagePullBackOff|ErrImagePull'; then
    failover_say "Fixing ${ctx}/${deploy} image for reliable pull:"
    failover_say "  was: ${current}"
    failover_say "  now: ${desired}"
    oc --context "${ctx}" -n "${ns}" set image "deploy/${deploy}" "${deploy}=${desired}" >/dev/null
    oc --context "${ctx}" -n "${ns}" patch "deploy/${deploy}" --type strategic \
      -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"quay-pull"}]}}}}' >/dev/null 2>&1 || true
    oc --context "${ctx}" -n "${ns}" patch "deploy/${deploy}" --type json \
      -p '[{"op":"remove","path":"/spec/template/metadata/annotations/alpha.image.policy.openshift.io~1resolve-names"}]' \
      >/dev/null 2>&1 || true
  fi
}

failover_wait_deploy() {
  local ctx="$1" ns="$2" deploy="$3" timeout="${4:-300}"
  local i phase problems
  failover_say "Waiting for ${ctx}/${ns}/${deploy} ready (timeout ${timeout}s)…"
  failover_ensure_quay_image "${ctx}" "${ns}" "${deploy}"
  if oc --context "${ctx}" -n "${ns}" rollout status "deploy/${deploy}" --timeout="${timeout}s" 2>/dev/null; then
    failover_say "✓ ${deploy} ready on ${ctx}"
    return 0
  fi
  echo
  failover_say "⚠ ${deploy} on ${ctx} not ready within ${timeout}s — diagnosing:"
  oc --context "${ctx}" -n "${ns}" get deploy "${deploy}" \
    -o jsonpath='  image={.spec.template.spec.containers[0].image}{"\n"}  ready={.status.readyReplicas}/{.status.replicas}{"\n"}' 2>/dev/null || true
  problems="$(failover_pod_problems "${ctx}" "${ns}" "${deploy}")"
  if [[ -n "${problems}" ]]; then
    while IFS= read -r line; do
      failover_say "  pod: ${line}"
    done <<< "${problems}"
  fi
  # One repair attempt for ImagePullBackOff caused by local IS rewrite
  if echo "${problems}" | grep -q ImagePullBackOff; then
    failover_ensure_quay_image "${ctx}" "${ns}" "${deploy}"
    failover_say "Retrying rollout after image fix…"
    if oc --context "${ctx}" -n "${ns}" rollout status "deploy/${deploy}" --timeout=180s 2>/dev/null; then
      failover_say "✓ ${deploy} ready on ${ctx} after image fix"
      return 0
    fi
  fi
  failover_say "Continue the demo; fix image/pull secrets if pods stay pending."
  return 1
}

failover_traffic_loop() {
  local phase="$1" base="$2" ns="$3" kc="${4:-$(failover_keycloak_url)}"
  local tok result code serving rows ok=0 fail=0
  tok="$(failover_get_token "${kc}")"
  [[ -n "${tok}" ]] || { echo "[${phase}] no token"; return 1; }
  echo "Traffic → ${base}"
  echo "Screen: one status line | details → ${DETAIL_LOG:-"(no log)"}"
  echo "CTRL+C to stop."
  echo
  while true; do
    result="$(failover_call_customers "${base}" "${tok}")"
    code="${result%%|*}"
    serving="$(failover_infer_serving "$(echo "${result}" | cut -d'|' -f2)" "${code}" "${ns}")"
    rows="$(echo "${result}" | cut -d'|' -f3)"
    if [[ "${code}" =~ ^2 ]]; then
      ok=$((ok + 1))
      failover_show_line "${code}" "${serving}" "${rows}" "${phase} #${ok}" "${ns}"
    else
      fail=$((fail + 1))
      failover_show_line "${code}" "${serving}" "${rows}" "${phase} !${fail}" "${ns}"
      if [[ "${code}" == "401" || "${code}" == "403" ]]; then
        tok="$(failover_get_token "${kc}")"
      fi
    fi
    sleep "${INTERVAL:-1}"
  done
}

failover_sample_window() {
  local phase="$1" base="$2" ns="$3" n="${4:-25}"
  local kc tok result code serving rows ok=0 fail=0 i last="?"
  local seen_east=0 seen_west=0
  kc="$(failover_keycloak_url)"
  tok="$(failover_get_token "${kc}")"
  for i in $(seq 1 "${n}"); do
    result="$(failover_call_customers "${base}" "${tok}")"
    code="${result%%|*}"
    serving="$(failover_infer_serving "$(echo "${result}" | cut -d'|' -f2)" "${code}" "${ns}")"
    rows="$(echo "${result}" | cut -d'|' -f3)"
    last="${serving}"
    case "${serving}" in
      east|~east) seen_east=1 ;;
      west|~west) seen_west=1 ;;
    esac
    if [[ "${code}" =~ ^2 ]]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    failover_show_line "${code}" "${serving}" "${rows}" "${phase} ${i}/${n}" "${ns}"
    sleep 1
  done
  echo
  echo
  echo "Result: ${ok} OK / ${fail} errors   last serving=${last}"
  if [[ "${seen_east}" -eq 1 ]]; then failover_say "Observed serving east (header or inferred)."; fi
  if [[ "${seen_west}" -eq 1 ]]; then failover_say "Observed serving west (header or inferred)."; fi
}

failover_print_route_check() {
  local label="$1" result="$2"
  local code serving rows
  code="${result%%|*}"
  serving="$(echo "${result}" | cut -d'|' -f2)"
  rows="$(echo "${result}" | cut -d'|' -f3)"
  if [[ "${code}" =~ ^2 ]]; then
    printf '  %-5s  API OK  %-3s   serving=%-5s  rows=%s\n' "${label}" "${code}" "${serving}" "${rows}"
  else
    printf '  %-5s  API FAIL %-3s  (expected if this ingress was drained)\n' "${label}" "${code}"
  fi
}
