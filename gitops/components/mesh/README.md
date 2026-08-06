# OSSM 3.4 ambient mesh (east / west)

GitOps manifests for Sail Operator ambient mode (Istio **v1.30-latest**), multi-primary peering, and DestinationRule locality failover for `banking-service`.

Ambient dataplane namespaces (mTLS via ztunnel): **`banking-apps`** (api-gateway + banking-service) and **`banking-db`** (PostgreSQL). Live failover demo: [`scripts/demo-mesh-failover.sh`](../../../scripts/demo-mesh-failover.sh).

Patterns adapted from [ossm3-ambient-mode](https://github.com/panchoraposo/ossm3-ambient-mode) (`istio1.29` / multi-cluster roles).

## Included

| Resource | Purpose |
| --- | --- |
| `Istio` / `IstioCNI` / `ZTunnel` | Ambient control + data plane |
| `Gateway/istio-eastwestgateway` | HBONE east-west gateway |
| `Service` + `Route` (passthrough) | HTTPS 443→15008 for peer reachability |
| `Gateway/banking-service-waypoint` | L7 waypoint for banking-service |
| `DestinationRule/banking-service-failover` | outlierDetection + `localityLbSetting.failoverPriority` |

PostgreSQL and Keycloak Services are **not** labeled `istio.io/global` — failover is mesh traffic only.

## Multi-network (overlapping pod CIDRs)

Sandboxes typically reuse the same pod CIDR on every cluster. Ambient then **must** send
cross-cluster traffic through the east-west HBONE gateway (`gatewayClassName: istio-east-west`)
with a **shared root CA**.

Required once after both meshes are Ready:

```bash
scripts/mesh/sync-shared-cacerts.sh          # shared root → istio-system/cacerts
scripts/mesh/exchange-remote-secrets.sh      # east ↔ west istiod peering
scripts/mesh/sync-eastwest-gateway-ips.sh    # LB hostname → Gateway status IPs (AWS)
```

GitOps sets `AMBIENT_ENABLE_MULTI_NETWORK=true`, `topology.istio.io/network` on
`istio-system` + the EW Gateway, and `global.network` per overlay (`network1` / `network2`).

Do **not** label application namespaces with `topology.istio.io/network` unless you have
re-validated waypoint L7 (historically VIP prefix issues on older OSSM ambient builds).
Classic `global.meshNetworks` maps are still omitted — ambient multi-network uses the
pilot env flag + EW Gateway discovery instead.

## Locality failover note

`banking-service` is `istio.io/global=true` + `istio.io/use-waypoint=banking-service-waypoint`.
The waypoint itself stays **cluster-local** (no `istio.io/global`) so ztunnel always sends
L7 traffic to the **local** waypoint; that waypoint then fails over to peer endpoints over
EW HBONE (needs `sync-eastwest-gateway-ips.sh` on AWS hostname LBs).

DestinationRule `banking-service-failover` adds `outlierDetection` +
`localityLbSetting.failoverPriority: topology.istio.io/cluster`.

## Not applied by Argo

Remote secrets / peering must be exchanged once both clusters exist:

```bash
scripts/mesh/exchange-remote-secrets.sh
```

See [docs/mesh-failover.md](../../../docs/mesh-failover.md) (live demo) and [docs/multi-cluster.md](../../../docs/multi-cluster.md) (install/peering).
