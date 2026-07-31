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

Each request prints a demo card:
  ▶ curl target URL (which OpenShift Route you are hitting)
  ◀ HTTP status + ★ EAST/WEST ★ (which cluster ran banking-service)
  customer list + pretty JSON body (Ada / Grace / Alan)
  pod counts east/west for banking-service and api-gateway

Watch ★ WEST ★ appear while east banking-service pods = 0 → that is failover.

EOF
}

# Compact JSON for screen + log.
failover_compact_body() {
  local file="$1"
  jq -c . "${file}" 2>/dev/null || tr '\n' ' ' < "${file}"
}

# Encode/decode body so it survives command substitution (no |/newline issues).
failover_b64_encode() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

failover_b64_decode() {
  printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null || true
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

# Returns: code|serving|rows|body_b64
# serving is the X-Banking-Cluster header, or "?" if absent.
failover_call_customers() {
  local base="$1" token="$2"
  local hdrs body code cluster bytes rows compact body_b64
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
  rows="$(jq -r 'if type=="array" then length else "?" end' "${body}" 2>/dev/null || echo "?")"
  compact="$(failover_compact_body "${body}")"
  body_b64="$(failover_b64_encode "${compact}")"
  failover_detail "---- $(date -u +%Y-%m-%dT%H:%M:%SZ) GET ${base}/api/v1/customers"
  failover_detail "HTTP ${code}  serving=${cluster}  rows=${rows}  bytes=${bytes}"
  failover_detail "body: ${compact}"
  rm -f "${hdrs}" "${body}"
  printf '%s|%s|%s|%s\n' "${code}" "${cluster}" "${rows}" "${body_b64}"
}

# Full decoded JSON body from a call result (may be empty string).
failover_result_json() {
  local result="$1"
  local b64
  b64="$(echo "${result}" | cut -d'|' -f4)"
  [[ -n "${b64}" ]] || return 0
  failover_b64_decode "${b64}"
}

failover_serving_label() {
  case "$1" in
    east|~east) echo "EAST" ;;
    west|~west) echo "WEST" ;;
    "?"|"") echo "UNKNOWN" ;;
    *) echo "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" ;;
  esac
}

failover_print_customers() {
  local json="$1"
  if [[ -z "${json}" || "${json}" == "null" ]]; then
    echo "    (no body)"
    return
  fi
  if ! echo "${json}" | jq -e 'type=="array"' >/dev/null 2>&1; then
    echo "    (non-JSON or error body)"
    return
  fi
  local n
  n="$(echo "${json}" | jq 'length')"
  if [[ "${n}" == "0" ]]; then
    echo "    (empty list — run preflight to seed demo customers)"
    return
  fi
  echo "${json}" | jq -r '.[] | "    #\(.id)  \(.firstName) \(.lastName)    \(.email)"'
}

failover_print_body_pretty() {
  local json="$1"
  if [[ -z "${json}" ]]; then
    echo "    (empty)"
    return
  fi
  # Color when stdout is a TTY; focused fields for the audience.
  if [[ -t 1 ]]; then
    echo "${json}" | jq -C '[.[]? | {id, firstName, lastName, email}] // .' 2>/dev/null \
      | sed 's/^/    /' && return
  fi
  echo "${json}" | jq '[.[]? | {id, firstName, lastName, email}] // .' 2>/dev/null \
    | sed 's/^/    /' || echo "    ${json}"
}

failover_story_path() {
  local serving="$1" ns="$2"
  local east_svc west_svc
  east_svc="$(failover_replicas east "${ns}" banking-service)"
  west_svc="$(failover_replicas west "${ns}" banking-service)"
  case "$(failover_serving_label "${serving}")" in
    WEST)
      if [[ "${east_svc}" == "0" ]]; then
        echo "    path: client → east Route → east api-gateway ══Skupper/mesh══▶ west banking-service"
      else
        echo "    path: client → Route → api-gateway → west banking-service"
      fi
      ;;
    EAST)
      echo "    path: client → east Route → east api-gateway → east banking-service"
      ;;
    *)
      echo "    path: client → OpenShift Route → api-gateway → banking-service"
      ;;
  esac
}

failover_post_customer() {
  local base="$1" token="$2" first="$3" last="$4" email="$5" nid="$6"
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "${base}/api/v1/customers" \
    -d "{\"firstName\":\"${first}\",\"lastName\":\"${last}\",\"email\":\"${email}\",\"nationalId\":\"${nid}\"}" \
    || echo 000)"
  echo "${code}"
}

# Seed a few demo customers when GET /customers returns []. Call against each
# cluster Route so east and west DBs both have data for failover demos.
failover_ensure_demo_customers() {
  local base="$1" token="$2" label="${3:-cluster}"
  local result code rows created=0
  result="$(failover_call_customers "${base}" "${token}")"
  code="${result%%|*}"
  rows="$(echo "${result}" | cut -d'|' -f3)"
  if [[ ! "${code}" =~ ^2 ]]; then
    failover_say "WARN: cannot seed ${label} — GET customers returned HTTP ${code}"
    return 1
  fi
  if [[ "${rows}" != "0" && "${rows}" != "?" ]]; then
    failover_say "${label}: already has ${rows} customer(s) — skipping seed"
    return 0
  fi
  failover_say "${label}: DB empty — seeding demo customers…"
  local first last email nid http
  # Stable demo identities (idempotent enough: skip if email already exists → 4xx).
  while IFS='|' read -r first last email nid; do
    [[ -n "${first}" ]] || continue
    http="$(failover_post_customer "${base}" "${token}" "${first}" "${last}" "${email}" "${nid}")"
    if [[ "${http}" =~ ^2 ]]; then
      created=$((created + 1))
      failover_say "  + ${first} ${last} (${email}) HTTP ${http}"
    elif [[ "${http}" == "409" || "${http}" == "400" ]]; then
      failover_say "  · ${email} already present (HTTP ${http})"
    else
      failover_say "  WARN: create ${email} → HTTP ${http}"
    fi
  done <<'EOF'
Ada|Lovelace|ada@bank.demo|NID-DEMO-001
Grace|Hopper|grace@bank.demo|NID-DEMO-002
Alan|Turing|alan@bank.demo|NID-DEMO-003
EOF
  result="$(failover_call_customers "${base}" "${token}")"
  rows="$(echo "${result}" | cut -d'|' -f3)"
  failover_say "${label}: now rows=${rows} (created ${created})"
  [[ "${rows}" != "0" ]]
}

# Seed entry + peer Routes so failover still returns a non-empty body.
failover_seed_both_clusters() {
  local ns="$1" token="$2"
  local entry peer
  entry="$(failover_route_url "${ENTRY_CLUSTER:-east}" "${ns}")"
  peer="$(failover_route_url "${PEER_CLUSTER:-west}" "${ns}")"
  echo
  failover_say "Ensuring demo customers on both cluster DBs (so body is not [] after failover)…"
  failover_ensure_demo_customers "${entry}" "${token}" "${ENTRY_CLUSTER:-east}" || true
  failover_ensure_demo_customers "${peer}" "${token}" "${PEER_CLUSTER:-west}" || true
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

# High-impact request/response card for the live demo.
# Args: base_url code serving rows phase ns json_body
failover_show_exchange() {
  local base="$1" code="$2" serving="$3" rows="$4" phase="$5" ns="$6" json="${7:-}"
  local url="${base%/}/api/v1/customers"
  local east_svc west_svc east_gw west_gw label mark
  east_svc="$(failover_replicas east "${ns}" banking-service)"
  west_svc="$(failover_replicas west "${ns}" banking-service)"
  east_gw="$(failover_replicas east "${ns}" api-gateway)"
  west_gw="$(failover_replicas west "${ns}" api-gateway)"
  label="$(failover_serving_label "${serving}")"
  if [[ "${code}" =~ ^2 ]]; then mark="OK"; else mark="FAIL"; fi

  echo
  echo "════════════════════════════════════════════════════════════════"
  printf ' %s   %s\n' "$(date +%H:%M:%S)" "${phase}"
  echo "────────────────────────────────────────────────────────────────"
  echo " ▶  REQUEST"
  echo "    GET ${url}"
  echo "    curl -sk \\"
  echo "      -H 'Authorization: Bearer \$TOKEN' \\"
  echo "      -H 'Accept: application/json' \\"
  echo "      '${url}'"
  echo "────────────────────────────────────────────────────────────────"
  printf ' ◀  RESPONSE  HTTP %s (%s)   served by  ★ %s ★\n' "${code}" "${mark}" "${label}"
  printf '    banking-service pods:  east=%-3s west=%s\n' "${east_svc}" "${west_svc}"
  printf '    api-gateway pods:      east=%-3s west=%s\n' "${east_gw}" "${west_gw}"
  failover_story_path "${serving}" "${ns}"
  echo "────────────────────────────────────────────────────────────────"
  echo "    customers (${rows}):"
  failover_print_customers "${json}"
  echo
  echo "    body:"
  failover_print_body_pretty "${json}"
  echo "════════════════════════════════════════════════════════════════"
}

# Back-compat wrapper (older call sites).
failover_show_line() {
  local code="$1" serving="$2" rows="$3" phase="$4" ns="$5" body="${6:-}" base="${7:-}"
  if [[ -n "${base}" ]]; then
    failover_show_exchange "${base}" "${code}" "${serving}" "${rows}" "${phase}" "${ns}" "${body}"
  else
    failover_show_exchange "?" "${code}" "${serving}" "${rows}" "${phase}" "${ns}" "${body}"
  fi
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
  local tok result code serving rows json ok=0 fail=0
  tok="$(failover_get_token "${kc}")"
  [[ -n "${tok}" ]] || { echo "[${phase}] no token"; return 1; }
  echo
  echo "Live traffic against OpenShift Route:"
  echo "  ${base}/api/v1/customers"
  echo "Detail log → ${DETAIL_LOG:-"(none)"}   CTRL+C to stop."
  while true; do
    result="$(failover_call_customers "${base}" "${tok}")"
    code="${result%%|*}"
    serving="$(failover_infer_serving "$(echo "${result}" | cut -d'|' -f2)" "${code}" "${ns}")"
    rows="$(echo "${result}" | cut -d'|' -f3)"
    json="$(failover_result_json "${result}")"
    if [[ "${code}" =~ ^2 ]]; then
      ok=$((ok + 1))
      failover_show_exchange "${base}" "${code}" "${serving}" "${rows}" "${phase} #${ok}" "${ns}" "${json}"
    else
      fail=$((fail + 1))
      failover_show_exchange "${base}" "${code}" "${serving}" "${rows}" "${phase} FAIL#${fail}" "${ns}" "${json}"
      if [[ "${code}" == "401" || "${code}" == "403" ]]; then
        tok="$(failover_get_token "${kc}")"
      fi
    fi
    sleep "${INTERVAL:-0.4}"
  done
}

failover_sample_window() {
  local phase="$1" base="$2" ns="$3" n="${4:-${SAMPLE_COUNT:-8}}"
  local kc tok result code serving rows json ok=0 fail=0 i last="?"
  local seen_east=0 seen_west=0
  local gap="${SAMPLE_INTERVAL:-${INTERVAL:-0.4}}"
  kc="$(failover_keycloak_url)"
  tok="$(failover_get_token "${kc}")"
  echo
  echo "Sampling ${n}× against:"
  echo "  ${base}/api/v1/customers"
  for i in $(seq 1 "${n}"); do
    result="$(failover_call_customers "${base}" "${tok}")"
    code="${result%%|*}"
    serving="$(failover_infer_serving "$(echo "${result}" | cut -d'|' -f2)" "${code}" "${ns}")"
    rows="$(echo "${result}" | cut -d'|' -f3)"
    json="$(failover_result_json "${result}")"
    last="${serving}"
    case "${serving}" in
      east|~east) seen_east=1 ;;
      west|~west) seen_west=1 ;;
    esac
    if [[ "${code}" =~ ^2 ]]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    failover_show_exchange "${base}" "${code}" "${serving}" "${rows}" "${phase} ${i}/${n}" "${ns}" "${json}"
    sleep "${gap}"
  done
  echo
  echo "Result: ${ok} OK / ${fail} errors   last served by ★ $(failover_serving_label "${last}") ★"
  if [[ "${seen_east}" -eq 1 ]]; then failover_say "Observed traffic served on EAST."; fi
  if [[ "${seen_west}" -eq 1 ]]; then failover_say "Observed traffic served on WEST."; fi
}

# Args: label result [base_url] [ns]
failover_print_route_check() {
  local label="$1" result="$2" base="${3:-}" ns="${4:-${BANKING_NS:-banking-si-apps}}"
  local code serving rows json
  code="${result%%|*}"
  serving="$(echo "${result}" | cut -d'|' -f2)"
  rows="$(echo "${result}" | cut -d'|' -f3)"
  json="$(failover_result_json "${result}")"
  if [[ -n "${base}" ]]; then
    failover_show_exchange "${base}" "${code}" "${serving}" "${rows}" "check ${label}" "${ns}" "${json}"
    return
  fi
  if [[ "${code}" =~ ^2 ]]; then
    printf '  %-5s  API OK  %-3s   served by ★ %s ★   rows=%s\n' \
      "${label}" "${code}" "$(failover_serving_label "${serving}")" "${rows}"
    failover_print_customers "${json}"
    echo "    body:"
    failover_print_body_pretty "${json}"
  else
    printf '  %-5s  API FAIL %-3s  (expected if this ingress was drained)\n' "${label}" "${code}"
    [[ -n "${json}" ]] && { echo "    body:"; failover_print_body_pretty "${json}"; }
  fi
}
