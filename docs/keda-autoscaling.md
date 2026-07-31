# Custom Metrics Autoscaler (KEDA) for Spring apps

This demo uses the **Red Hat OpenShift Custom Metrics Autoscaler Operator** (CMA) — the supported build of [KEDA](https://keda.sh/) — to scale the Spring banking apps from **1** to about **10** pods based on CPU and Prometheus HTTP request rate.

Community KEDA is **not** used.

## What is installed

| Layer | Resource |
| --- | --- |
| Operator (wave 0) | Subscription `openshift-custom-metrics-autoscaler-operator` in `openshift-keda` ([`gitops/platform/operators-spoke`](../gitops/platform/operators-spoke)) |
| Operand (wave 1) | `KedaController` + cluster RBAC for Thanos queries ([`gitops/components/keda`](../gitops/components/keda)) |
| Per app namespace | `TriggerAuthentication` `keda-prom-auth` (bound SA token) in `banking-apps` / `banking-si-apps` |
| Per Deployment | `ScaledObject` + `ServiceMonitor` (mesh) or `PodMonitor` (SI `banking-service`) |

Applies to **both** demo stacks on east/west:

- Mesh: `banking-apps` — `api-gateway`, `banking-service`
- Service Interconnect: `banking-si-apps` — `api-gateway`, `banking-service`

## ScaledObject policy

Each ScaledObject:

- `minReplicaCount: 1` (no scale-to-zero)
- `maxReplicaCount: 10`
- `pollingInterval: 15` / `cooldownPeriod: 60`
- Triggers:
  1. **CPU** — `Utilization` target `60%` (baseline)
  2. **Prometheus** — `sum(rate(http_server_requests_seconds_count{namespace=…,container=…}[1m]))` with `threshold: "10"` (desired replicas ≈ metric / threshold)

Metrics path:

```text
Spring /actuator/prometheus
  → ServiceMonitor / PodMonitor (UWM)
  → thanos-querier.openshift-monitoring:9091
  → CMA prometheus trigger (bearer token via TriggerAuthentication)
  → HPA owned by ScaledObject
```

User-workload monitoring must stay enabled ([`gitops/components/monitoring-user-workload`](../gitops/components/monitoring-user-workload)).

## Spring metrics and health

Apps expose:

- `/actuator/health/liveness` and `/actuator/health/readiness` (unauthenticated)
- `/actuator/prometheus` (Micrometer; unauthenticated for in-cluster scrape)

**banking-service** readiness includes the **db** indicator so pods are not Ready until PostgreSQL answers. Deployments use:

| Probe | Timing |
| --- | --- |
| `startupProbe` → liveness | every 10s, fail after 30 (~5 min cold start) |
| `readinessProbe` | every 5s, fail after 3 |
| `livenessProbe` | every 15s, fail after 3 |

## Demo

```bash
# Mesh stack on east (default)
./scripts/demo-keda-scale.sh

# SI stack
BANKING_NS=banking-si-apps ./scripts/demo-keda-scale.sh

# Heavier / longer load
CONCURRENCY=60 LOAD_SECONDS=180 ./scripts/demo-keda-scale.sh load
```

Requires `hey` (preferred) or Apache Bench (`ab`), plus a working Keycloak token (same credentials as the failover demos).

Useful watches:

```bash
oc --context east -n banking-apps get scaledobject,hpa,pods -w
oc --context east -n openshift-keda get pods
```

## Notes

- Do **not** attach a separate HPA to the same Deployment; CMA creates and owns the HPA.
- After app image changes that add `/actuator/prometheus`, rebuild/push via the usual CI path so running pods expose the metric.
- Threshold `10` is tuned for a live demo (~100 RPS → ~10 replicas). Adjust `ScaledObject` metadata if your load tool or cluster size differs.
