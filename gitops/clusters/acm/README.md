# Cluster acm (hub)

| Install | Notes |
| --- | --- |
| RHACM | Hub for ManagedClusters, Placement, ApplicationSets |
| OpenShift GitOps | Hosts `banking-demo-acm-root` + ApplicationSets |
| CyberArk Conjur | `gitops/components/conjur` — source of truth for secrets |
| OpenShift Data Foundation | MCG object storage for Quay + TPA |
| Red Hat Quay | Signed images, SBOMs, attestations |
| Trusted Artifact Signer | Fulcio / Rekor / TUF for cosign |
| Trusted Profile Analyzer | Private SCA backend for RHDA |
| Jenkins + BuildConfigs | CI: Build → Quay SBOM/sign/attest → GitOps |
| Hub Kiali (optional) | Multi-cluster view; secrets via `scripts/mesh/sync-kiali-multicluster-secrets.sh` |

Console banner text: **Hub Cluster** (`scripts/apply-console-banners.sh`).

## Bootstrap (do not apply until the cluster is ready)

```bash
oc --context acm apply -f gitops/bootstrap/acm-root.yaml -n openshift-gitops

oc --context acm label managedcluster east \
  cluster.open-cluster-management.io/clusterset=banking-spokes \
  banking-demo/role=spoke banking-demo/region=east --overwrite
oc --context acm label managedcluster west \
  cluster.open-cluster-management.io/clusterset=banking-spokes \
  banking-demo/role=spoke banking-demo/region=west --overwrite
oc --context acm apply -k gitops/acm
```

See [docs/supply-chain.md](../../../docs/supply-chain.md).

## Kube context

Expected local kubeconfig context name: **`acm`**.
