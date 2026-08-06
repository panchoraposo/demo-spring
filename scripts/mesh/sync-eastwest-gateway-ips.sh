#!/usr/bin/env bash
# Resolve AWS/OpenShift EW LoadBalancer hostnames to IPs and patch Gateway status.
#
# Ambient ztunnel NetworkGateways need IP addresses (hostname-only gateways end up
# with empty workloadIps / missing HBONE port). Waypoint EDS can use the IPs for
# cross-network failover when the local banking-service is scaled to 0.
#
# Usage:
#   ./scripts/mesh/sync-eastwest-gateway-ips.sh           # east + west
#   ./scripts/mesh/sync-eastwest-gateway-ips.sh east
set -euo pipefail

if [[ $# -gt 0 ]]; then
  CONTEXTS=("$@")
else
  CONTEXTS=(east west)
fi
NS=istio-system
GW=istio-eastwestgateway

resolve_ips() {
  local host="$1"
  # Prefer getent/host; fall back to dig/nslookup.
  if command -v getent >/dev/null 2>&1; then
    getent ahosts "$host" | awk '/STREAM/ {print $1}' | sort -u
    return
  fi
  if command -v dig >/dev/null 2>&1; then
    dig +short "$host" A | grep -E '^[0-9.]+$' | sort -u
    return
  fi
  python3 - "$host" <<'PY'
import socket, sys
host = sys.argv[1]
ips = sorted({ai[4][0] for ai in socket.getaddrinfo(host, None, socket.AF_INET)})
print("\n".join(ips))
PY
}

for ctx in "${CONTEXTS[@]}"; do
  host="$(oc --context "$ctx" -n "$NS" get svc "$GW" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    ip="$(oc --context "$ctx" -n "$NS" get svc "$GW" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      echo "[$ctx] EW gateway already has IP $ip — patching status"
      oc --context "$ctx" -n "$NS" patch gateway "$GW" --subresource=status --type=merge -p \
        "{\"status\":{\"addresses\":[{\"type\":\"IPAddress\",\"value\":\"$ip\"}]}}"
      continue
    fi
    echo "[$ctx] WARN: no LoadBalancer hostname/IP on $GW — skip" >&2
    continue
  fi

  # Bash 3.2-compatible (macOS) — avoid mapfile.
  ips=()
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && ips+=("$ip")
  done < <(resolve_ips "$host")
  if [[ ${#ips[@]} -eq 0 ]]; then
    echo "[$ctx] WARN: could not resolve $host" >&2
    continue
  fi

  addr_json=""
  for ip in "${ips[@]}"; do
    addr_json+="{\"type\":\"IPAddress\",\"value\":\"$ip\"},"
  done
  addr_json+="{\"type\":\"Hostname\",\"value\":\"$host\"}"

  echo "[$ctx] patching $GW status addresses: ${ips[*]} + hostname"
  oc --context "$ctx" -n "$NS" patch gateway "$GW" --subresource=status --type=merge -p \
    "{\"status\":{\"addresses\":[${addr_json}]}}"
done
