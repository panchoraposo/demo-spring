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
```

GitOps sets `AMBIENT_ENABLE_MULTI_NETWORK=true`, `topology.istio.io/network` on
`istio-system` + the EW Gateway, and `global.network` per overlay (`network1` / `network2`).

Do **not** label application namespaces with `topology.istio.io/network` unless you have
re-validated waypoint L7 (historically VIP prefix issues on older OSSM ambient builds).
Classic `global.meshNetworks` maps are still omitted — ambient multi-network uses the
pilot env flag + EW Gateway discovery instead.

## Locality failover note

The ambient reference repo primarily demonstrates `outlierDetection` circuit breaking. The DestinationRule here **adds** `localityLbSetting.failoverPriority: topology.istio.io/cluster` for east↔west traffic preference after ejection — validate on your clusters when both meshes are peered.

## Not applied by Argo

Remote secrets / peering must be exchanged once both clusters exist:

```bash
scripts/mesh/exchange-remote-secrets.sh
```

See [docs/multi-cluster.md](../../../docs/multi-cluster.md).
