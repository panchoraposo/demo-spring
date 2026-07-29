# OSSM 3.4 ambient mesh (east / west)

GitOps manifests for Sail Operator ambient mode (Istio **v1.30-latest**), multi-primary peering, and DestinationRule locality failover for `banking-service`.

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

## Intentionally omitted: `meshNetworks` / network topology labels

In ambient mode, enabling `global.meshNetworks` and `topology.istio.io/network` has caused ztunnel to prefix VIPs in a way that breaks waypoint L7 interception (seen on OSSM 3.2 / Istio 1.27 ambient demos). This repo relies on:

- multi-primary remote secrets (`scripts/mesh/exchange-remote-secrets.sh`)
- `istio.io/global: "true"` on `banking-service`
- east-west HBONE gateway + passthrough Route

Do **not** re-enable `meshNetworks` without re-validating waypoints on OSSM 3.4.

## Locality failover note

The ambient reference repo primarily demonstrates `outlierDetection` circuit breaking. The DestinationRule here **adds** `localityLbSetting.failoverPriority: topology.istio.io/cluster` for east↔west traffic preference after ejection — validate on your clusters when both meshes are peered.

## Not applied by Argo

Remote secrets / peering must be exchanged once both clusters exist:

```bash
scripts/mesh/exchange-remote-secrets.sh
```

See [docs/multi-cluster.md](../../../docs/multi-cluster.md).
