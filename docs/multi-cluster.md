# Multi-cluster (acm / east / west)

Layout for RHACM ApplicationSets plus per-cluster regional data. Prefer the Ansible installer once clusters are joined.

## Topology

| Cluster | Role | Workloads |
| --- | --- | --- |
| **acm** | Hub | RHACM, GitOps, Conjur, Keycloak, Jenkins, ODF, Quay, RHTAS, TPA, Dev Spaces, hub Kiali MC + OSSMC, promxy + Perses |
| **east** | Managed cluster | GitOps, ESO, OSSM 3.4 ambient, CMA (KEDA), PostgreSQL, Spring apps |
| **west** | Managed cluster | Same as east (independent DB) |

**Mesh failover is traffic only.** Scaling east `banking-service` to 0 lets ambient locality send traffic to west endpoints. PostgreSQL is **not** shared.

A **separate** failover path uses Red Hat Service Interconnect in namespaces `banking-si-apps` / `banking-si-db`, entered via per-cluster OpenShift Routes — see [service-interconnect-failover.md](service-interconnect-failover.md). Do not mix those namespaces with the ambient mesh demo.

**OIDC is centralized on the hub**: a single Keycloak instance on **acm** (`banking-idp` Route `sso`) provides realms `banking` (Spring apps) and `trustify` (TPA).

## Recommended install (Ansible)

Prerequisites: RHACM on acm; east/west joined as Available ManagedClusters; `oc` contexts `acm`/`east`/`west`; `istioctl` installed.

```bash
cd ansible
cp inventory.example.yml inventory.yml
# Set git_repo_url + git_target_revision to a per-environment branch/fork
ansible-playbook -i inventory.yml playbooks/install.yml
# If Argo must read the rewritten env files from Git:
# ansible-playbook -i inventory.yml playbooks/install.yml -e auto_push_env=true
```

What the playbook covers (env discovery, hub root, Argo cluster secrets, Conjur/Quay sync, mesh peering, promxy tokens, dashboard) is listed in [`ansible/README.md`](../ansible/README.md).

## Manual bootstrap order

1. Install RHACM on **acm**; join **east** and **west** as ManagedClusters.
2. Install OpenShift GitOps on acm; run [`scripts/bootstrap-acm.sh`](../scripts/bootstrap-acm.sh) (applies acm-root only).
3. Optional Gitea seed: [`scripts/bootstrap-gitea.sh`](../scripts/bootstrap-gitea.sh).
4. Ensure hub capacity (required for Dev Spaces + Jenkins on small hubs):

```bash
# Some environments provision the hub with 0 workers by default.
oc --context acm -n openshift-machine-api get machineset.machine.openshift.io -o wide
oc --context acm -n openshift-machine-api scale machineset.machine.openshift.io/<worker-machineset> --replicas=1
oc --context acm get nodes -o wide
```

5. Label managed clusters and apply Placement + ApplicationSets:

```bash
oc --context acm label managedcluster east \
  cluster.open-cluster-management.io/clusterset=banking-managed \
  banking-demo/role=managed banking-demo/region=east --overwrite
oc --context acm label managedcluster west \
  cluster.open-cluster-management.io/clusterset=banking-managed \
  banking-demo/role=managed banking-demo/region=west --overwrite

# Hub Argo needs cluster Secrets labeled banking-demo/role=managed (Ansible register_argocd_clusters).
oc --context acm apply -k gitops/acm
```

6. Set environment values (Ansible `configure_environment` does this automatically):
   - Git repo URL + revision: `gitops/applications/{acm,east,west}/env/common.env`
   - Hub Keycloak + TPA domain values:
     - `gitops/components/keycloak/overlays/acm/env/keycloak.env` (Route host `sso.<appsDomain>`)
     - `gitops/components/trusted-profile-analyzer/env/tpa.env` (TPA `appDomain`)
   - Cluster OIDC issuer values (pointing to hub):
     - `gitops/components/{api-gateway,banking-service}/overlays/{east,west}/env/*.env`
   - Cluster Conjur URL (ESO ClusterSecretStore): `gitops/components/external-secrets/overlays/{east,west}/env/conjur.env`
7. After Conjur bootstrap on acm: [`scripts/sync-conjur-creds-to-clusters.sh`](../scripts/sync-conjur-creds-to-clusters.sh)
8. After Quay is HTTP-ready: [`scripts/bootstrap-quay-ci.sh`](../scripts/bootstrap-quay-ci.sh) then [`scripts/sync-quay-pull-secret-to-clusters.sh`](../scripts/sync-quay-pull-secret-to-clusters.sh)
9. After both meshes are Ready:
   - Shared CA: [`scripts/mesh/sync-shared-cacerts.sh`](../scripts/mesh/sync-shared-cacerts.sh)
   - Peering: [`scripts/mesh/exchange-remote-secrets.sh`](../scripts/mesh/exchange-remote-secrets.sh)
10. Hub Kiali multi-cluster secrets: [`scripts/mesh/sync-kiali-multicluster-secrets.sh`](../scripts/mesh/sync-kiali-multicluster-secrets.sh)
11. Cluster metrics for Kiali graphs: [`scripts/mesh/enable-user-workload-monitoring.sh`](../scripts/mesh/enable-user-workload-monitoring.sh) + mesh `PodMonitor`s, then hub promxy [`scripts/mesh/sync-promxy.sh`](../scripts/mesh/sync-promxy.sh)
12. Perses (multi-cluster PromQL dashboards on acm): Cluster Observability Operator + GitOps [`gitops/components/perses`](../gitops/components/perses) (datasource = promxy). Open with [`scripts/perses-url.sh`](../scripts/perses-url.sh).
13. Console UX:
    - Banners: [`scripts/apply-console-banners.sh`](../scripts/apply-console-banners.sh)
    - ApplicationMenu links: [`scripts/apply-console-links.sh`](../scripts/apply-console-links.sh) (includes Perses)
14. Credentials dashboard (Ansible): `ansible-playbook -i ansible/inventory.example.yml ansible/playbooks/dashboard.yml`
15. Live mesh failover: [`scripts/demo-mesh-failover.sh`](../scripts/demo-mesh-failover.sh) — [mesh-failover.md](mesh-failover.md) (Kiali + Perses)
16. Optional SI failover: [`scripts/si/link-sites.sh`](../scripts/si/link-sites.sh) → [`scripts/demo-si-failover.sh`](../scripts/demo-si-failover.sh) — [service-interconnect-failover.md](service-interconnect-failover.md)
17. Perses dashboards: [`scripts/perses-url.sh`](../scripts/perses-url.sh) — [observability-perses.md](observability-perses.md)
18. Optional autoscaling (CMA / KEDA): [`scripts/demo-keda-scale.sh`](../scripts/demo-keda-scale.sh) — [keda-autoscaling.md](keda-autoscaling.md)

Managed cluster GitOps prerequisite: Subscription in `gitops/platform/operators-spoke` (ESO, Sail, GitOps, RHSI, CMA) once Applications start.

## Mesh peering checklist

- [ ] Sail / `servicemeshoperator3` Succeeded on east and west
- [ ] `Istio` / `IstioCNI` / `ZTunnel` Ready (`profile: ambient`, version `v1.30-latest`)
- [ ] `banking-apps` labeled `istio.io/dataplane-mode=ambient`
- [ ] `banking-service` Service has `istio.io/global=true` and waypoint label
- [ ] East-west Gateway `istio-eastwestgateway` present
- [ ] Passthrough Route `istio-eastwestgateway` (HTTPS→HBONE) present on both clusters
- [ ] Remote secrets exchanged both directions
- [ ] DestinationRule `banking-service-failover` present
- [ ] Shared `cacerts` installed (`scripts/mesh/sync-shared-cacerts.sh`)
- [ ] EW Gateway `gatewayClassName: istio-east-west` + `AMBIENT_ENABLE_MULTI_NETWORK=true`
- [ ] Hub Kiali Ready with remote secrets for east/west

## Failover and observability demos

Both failover demos enter via **per-cluster OpenShift Routes** (no shared global DNS):

```bash
./scripts/demo-mesh-failover.sh   # ambient mesh — see mesh-failover.md
./scripts/demo-si-failover.sh     # Service Interconnect — see service-interconnect-failover.md
./scripts/perses-url.sh           # Perses dashboards on acm console
```

| Demo | Doc |
| --- | --- |
| Mesh failover (Kiali + Perses) | [mesh-failover.md](mesh-failover.md) |
| SI failover (Network Observer + Perses) | [service-interconnect-failover.md](service-interconnect-failover.md) |
| Perses / promxy setup and dashboards | [observability-perses.md](observability-perses.md) |

## Autoscaling demo (CMA / KEDA)

Spring apps on east/west scale on CPU + Prometheus HTTP RPS (max 10). Idle stays at 1 replica — generate load to observe scale-out:

```bash
./scripts/demo-keda-scale.sh
# watch (one resource type with -w):
oc --context east -n banking-apps get hpa -w
```

Details: [keda-autoscaling.md](keda-autoscaling.md).

## CI images / supply chain

Jenkins on **acm** builds via OpenShift BuildConfigs, mirrors to **Quay**, generates SBOM + attestation + signature (RHTAS), then bumps `newTag`/`newName` on **both** east and west overlays. Details: [ci-cd.md](ci-cd.md), [supply-chain.md](supply-chain.md).

Console UX on acm:
- Banner **Hub Cluster** — GitOps [`gitops/components/console-banners`](../gitops/components/console-banners) (+ script for east/west).
- ApplicationMenu links (Gitea, Jenkins, Quay, Rekor Search UI, Kiali, Perses) — [`scripts/apply-console-links.sh`](../scripts/apply-console-links.sh).
- Service Mesh console (OSSMC) — [`gitops/components/kiali-multicluster/ossmconsole.yaml`](../gitops/components/kiali-multicluster/ossmconsole.yaml).
- Perses dashboards — [`gitops/components/perses`](../gitops/components/perses) (COO UIPlugin + promxy datasource).

## Repo paths

| Path | Purpose |
| --- | --- |
| [`gitops/applications/acm`](../gitops/applications/acm) | Hub Applications |
| [`gitops/applications/east`](../gitops/applications/east) / [`west`](../gitops/applications/west) | Managed-cluster Applications |
| [`gitops/acm`](../gitops/acm) | Placement + ApplicationSets |
| [`gitops/components/mesh`](../gitops/components/mesh) | OSSM ambient + failover |
| [`gitops/components/perses`](../gitops/components/perses) | Perses UIPlugin + dashboards on acm |
| [`gitops/components/promxy`](../gitops/components/promxy) | Multi-cluster PromQL federation |
| [`gitops/components/keda`](../gitops/components/keda) | CMA `KedaController` + Thanos RBAC |
| [`gitops/platform/operators-spoke`](../gitops/platform/operators-spoke) | Spoke operators including CMA Subscription |
