# Cluster acm (hub)

| Install | Notes |
| --- | --- |
| RHACM | Hub for ManagedClusters, Placement, ApplicationSets |
| OpenShift GitOps | Hosts `banking-demo-acm-root` + ApplicationSets |
| CyberArk Conjur | `gitops/components/conjur` — source of truth for secrets |
| Red Hat build of Keycloak | Realms `banking` + `trustify` in `banking-idp` (Route `sso`) |
| OpenShift Data Foundation | MCG object storage for Quay + TPA |
| Red Hat Quay | Signed images, SBOMs, attestations |
| Trusted Artifact Signer | Fulcio / Rekor / TUF for cosign |
| Trusted Profile Analyzer | Private SCA backend for RHDA |
| OpenShift Dev Spaces | CheCluster + RHDA → TPA |
| Jenkins + BuildConfigs | CI: Build → Quay SBOM/sign/attest → GitOps |
| Hub Kiali + promxy | Multi-cluster view; secrets via Ansible / mesh scripts |

Console banner text: **Hub Cluster** (`scripts/apply-console-banners.sh`).

## Bootstrap (do not apply until the cluster is ready)

Prefer Ansible: [`ansible/README.md`](../../../ansible/README.md).

```bash
oc --context acm apply -f gitops/bootstrap/acm-root.yaml -n openshift-gitops

oc --context acm label managedcluster east \
  cluster.open-cluster-management.io/clusterset=banking-managed \
  banking-demo/role=managed banking-demo/region=east --overwrite
oc --context acm label managedcluster west \
  cluster.open-cluster-management.io/clusterset=banking-managed \
  banking-demo/role=managed banking-demo/region=west --overwrite
# Hub Argo cluster Secrets must also be labeled banking-demo/role=managed
oc --context acm apply -k gitops/acm
```

See [docs/supply-chain.md](../../../docs/supply-chain.md).

## Kube context

Expected local kubeconfig context name: **`acm`**.
