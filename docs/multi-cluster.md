# Multi-cluster (acm / east / west)

Prep layout for RHACM ApplicationSets plus per-spoke data/IdP. **Do not apply** until clusters are ready.

## Topology

| Cluster | Role | Workloads |
| --- | --- | --- |
| **acm** | Hub | RHACM, GitOps, Gitea, Conjur, Jenkins, ODF, Quay, RHTAS, TPA, hub Kiali MC + OSSMC |
| **east** | Spoke | GitOps, ESO, OSSM 3.4 ambient, Dev Spaces, PostgreSQL, Spring apps |
| **west** | Spoke | Same as east (independent DB) |

**Failover is mesh traffic only.** Scaling east `banking-service` to 0 lets ambient locality send traffic to west endpoints. PostgreSQL is **not** shared.

**OIDC is centralized on the hub**: a single Keycloak instance on **acm** provides two realms:

- `banking` (Spring apps)
- `trustify` (TPA)

## Bootstrap order

1. Install RHACM on **acm**; join **east** and **west** as ManagedClusters.
2. Install OpenShift GitOps on acm; run [`scripts/bootstrap-acm.sh`](../scripts/bootstrap-acm.sh) (installs Gitea, seeds `banking/demo-spring`, stores CI PAT in Conjur, applies acm-root).
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
5. Set environment values (no repo-wide placeholder script):
   - Git repo URL + revision: `gitops/applications/{acm,east,west}/env/common.env`
   - Spoke Keycloak + issuer values:
     - `gitops/components/keycloak/overlays/{east,west}/env/keycloak.env`
     - `gitops/components/{api-gateway,banking-service}/overlays/{east,west}/env/*.env`
   - Spoke Conjur URL (ESO ClusterSecretStore): `gitops/components/external-secrets/overlays/{east,west}/env/conjur.env`
6. After Conjur bootstrap on acm: [`scripts/sync-conjur-creds-to-spokes.sh`](../scripts/sync-conjur-creds-to-spokes.sh)
7. After both meshes are Ready:
   - Shared CA: [`scripts/mesh/sync-shared-cacerts.sh`](../scripts/mesh/sync-shared-cacerts.sh)
   - Peering: [`scripts/mesh/exchange-remote-secrets.sh`](../scripts/mesh/exchange-remote-secrets.sh)
8. Hub Kiali multi-cluster secrets: [`scripts/mesh/sync-kiali-multicluster-secrets.sh`](../scripts/mesh/sync-kiali-multicluster-secrets.sh) (feeds OSSMC / Service Mesh console on acm).
9. Spoke metrics for Kiali graphs: [`scripts/mesh/enable-user-workload-monitoring.sh`](../scripts/mesh/enable-user-workload-monitoring.sh) + mesh `PodMonitor`s, then hub promxy [`scripts/mesh/sync-promxy.sh`](../scripts/mesh/sync-promxy.sh).
10. Live failover demo: [`scripts/demo-mesh-failover.sh`](../scripts/demo-mesh-failover.sh)
10. After Jenkins / Quay / RHTAS Routes exist: [`scripts/apply-console-banners.sh`](../scripts/apply-console-banners.sh) (spoke banners + ApplicationMenu ConsoleLinks).

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
- [ ] Shared `cacerts` installed (`scripts/mesh/sync-shared-cacerts.sh`)
- [ ] EW Gateway `gatewayClassName: istio-east-west` + `AMBIENT_ENABLE_MULTI_NETWORK=true`
- [ ] Hub Kiali Ready with remote secrets for east/west

## Failover demo (Kiali + mesh)

Interactive presenter script (traffic loop, scale-down, recover):

```bash
./scripts/demo-mesh-failover.sh
```

Kiali on ACM: `https://$(oc --context acm -n istio-system get route kiali -o jsonpath='{.spec.host}')`

Manual equivalent:

```bash
# Pause Argo self-heal, then drain local banking-service
oc --context east -n openshift-gitops patch applications.argoproj.io banking-service \
  --type merge -p '{"spec":{"syncPolicy":null}}'
oc --context east -n banking-apps scale deploy/banking-service --replicas=0

# api-gateway on east keeps calling banking-service.banking-apps.svc.cluster.local;
# ambient multi-network + DestinationRule should shift to west endpoints (EW HBONE).
# West PG data may differ; JWT issuers are trusted on both spokes (OIDC_TRUSTED_ISSUERS).

oc --context east -n banking-apps scale deploy/banking-service --replicas=1
```

## CI images / supply chain

Jenkins on **acm** builds via OpenShift BuildConfigs, mirrors to **Quay**, generates SBOM + attestation + signature (RHTAS), then bumps `newTag`/`newName` on **both** east and west overlays. Details: [ci-cd.md](ci-cd.md), [supply-chain.md](supply-chain.md).

Legacy ImageStream mirror (if Quay is not yet Ready):

```bash
scripts/mirror-image-to-spokes.sh banking-service <tag>
scripts/mirror-image-to-spokes.sh api-gateway <tag>
```

Console UX on acm:
- Banner **Hub Cluster** — GitOps [`gitops/components/console-banners`](../gitops/components/console-banners) (+ script for east/west).
- ApplicationMenu links (Gitea, Jenkins, Quay, Rekor Search UI, Kiali) — [`scripts/apply-console-links.sh`](../scripts/apply-console-links.sh) (Gitea also created by `bootstrap-gitea.sh`).
- Service Mesh console (OSSMC) — [`gitops/components/kiali-multicluster/ossmconsole.yaml`](../gitops/components/kiali-multicluster/ossmconsole.yaml); refresh the OpenShift console after the plugin is Ready.

## Repo paths

| Path | Purpose |
| --- | --- |
| [`gitops/applications/acm`](../gitops/applications/acm) | Hub Applications |
| [`gitops/applications/east`](../gitops/applications/east) / [`west`](../gitops/applications/west) | Spoke Applications |
| [`gitops/acm`](../gitops/acm) | Placement + ApplicationSets |
| [`gitops/components/mesh`](../gitops/components/mesh) | OSSM ambient + failover |
