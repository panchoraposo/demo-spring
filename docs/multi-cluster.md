# Multi-cluster (acm / east / west)

Prep layout for RHACM ApplicationSets plus per-spoke data/IdP. **Do not apply** until clusters are ready.

## Topology

| Cluster | Role | Workloads |
| --- | --- | --- |
| **acm** | Hub | RHACM, GitOps, Conjur, Jenkins, ODF, Quay, RHTAS, TPA, hub Kiali MC |
| **east** | Spoke | GitOps, ESO, OSSM 3.4 ambient, Dev Spaces, PostgreSQL, Keycloak, Spring apps |
| **west** | Spoke | Same as east (independent DB + IdP) |

**Failover is mesh traffic only.** Scaling east `banking-service` to 0 lets ambient locality send traffic to west endpoints. PostgreSQL and Keycloak are **not** shared; clients that land on west use west Keycloak (different issuer).

## Bootstrap order

1. Install RHACM on **acm**; join **east** and **west** as ManagedClusters.
2. Install OpenShift GitOps on acm; run [`scripts/bootstrap-acm.sh`](../scripts/bootstrap-acm.sh) (or apply [`gitops/bootstrap/acm-root.yaml`](../gitops/bootstrap/acm-root.yaml)).
3. Label spokes and apply Placement + ApplicationSets:

```bash
oc --context acm label managedcluster east \
  cluster.open-cluster-management.io/clusterset=banking-spokes \
  banking-demo/role=spoke banking-demo/region=east --overwrite
oc --context acm label managedcluster west \
  cluster.open-cluster-management.io/clusterset=banking-spokes \
  banking-demo/role=spoke banking-demo/region=west --overwrite

# Placement + ManagedClusterSetBinding live in openshift-gitops (with ApplicationSets).
oc --context acm apply -k gitops/acm
```

4. Ensure hub Argo can reach spoke APIs (ACM GitOps Cluster addon or cluster secrets).
5. Replace placeholders and commit:
   - `REPLACE_ME_ACM_APPS_DOMAIN` in spoke [`ClusterSecretStore`](../gitops/components/external-secrets/clustersecretstore-conjur.yaml)
   - `REPLACE_ME_WEST_APPS_DOMAIN` in api-gateway west overlay
6. After Conjur bootstrap on acm: [`scripts/sync-conjur-creds-to-spokes.sh`](../scripts/sync-conjur-creds-to-spokes.sh)
7. After both meshes are Ready: [`scripts/mesh/exchange-remote-secrets.sh`](../scripts/mesh/exchange-remote-secrets.sh)
8. Optional hub Kiali secrets: [`scripts/mesh/sync-kiali-multicluster-secrets.sh`](../scripts/mesh/sync-kiali-multicluster-secrets.sh)

Spoke GitOps prerequisite: Subscription in [`gitops/platform/operators-spoke`](../gitops/platform/operators-spoke) (synced once Applications start).

## Mesh peering checklist

- [ ] Sail / `servicemeshoperator3` Succeeded on east and west
- [ ] `Istio` / `IstioCNI` / `ZTunnel` Ready (`profile: ambient`, version `v1.30-latest`)
- [ ] `banking-apps` labeled `istio.io/dataplane-mode=ambient`
- [ ] `banking-service` Service has `istio.io/global=true` and waypoint label
- [ ] East-west Gateway `istio-eastwestgateway` present
- [ ] Passthrough Route `istio-eastwestgateway` (HTTPS→HBONE) present on both spokes
- [ ] Remote secrets exchanged both directions
- [ ] DestinationRule `banking-service-failover` present
- [ ] Do **not** enable `meshNetworks` / `topology.istio.io/network` until waypoints are re-validated (ambient VIP caveat)

## Failover demo

```bash
# From a client in-mesh (or via api-gateway on east) call banking-service.
oc --context east -n banking-apps scale deploy/banking-service --replicas=0

# Traffic to host banking-service.banking-apps.svc.cluster.local should fail over to west
# (outlierDetection + localityLbSetting.failoverPriority).
# West serves its own PostgreSQL/Keycloak — expect different data / issuer.

oc --context east -n banking-apps scale deploy/banking-service --replicas=1
```

## CI images / supply chain

Jenkins on **acm** builds via OpenShift BuildConfigs, mirrors to **Quay**, generates SBOM + attestation + signature (RHTAS), then bumps `newTag`/`newName` on **both** east and west overlays. Details: [ci-cd.md](ci-cd.md), [supply-chain.md](supply-chain.md).

Legacy ImageStream mirror (if Quay is not yet Ready):

```bash
scripts/mirror-image-to-spokes.sh banking-service <tag>
scripts/mirror-image-to-spokes.sh api-gateway <tag>
```

Console banners: `scripts/apply-console-banners.sh` (acm text: **Hub Cluster**).

## Repo paths

| Path | Purpose |
| --- | --- |
| [`gitops/applications/acm`](../gitops/applications/acm) | Hub Applications |
| [`gitops/applications/east`](../gitops/applications/east) / [`west`](../gitops/applications/west) | Spoke Applications |
| [`gitops/acm`](../gitops/acm) | Placement + ApplicationSets |
| [`gitops/components/mesh`](../gitops/components/mesh) | OSSM ambient + failover |
