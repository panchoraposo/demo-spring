# Cluster acm (hub)

| Install | Notes |
| --- | --- |
| RHACM | Hub for ManagedClusters, Placement, ApplicationSets |
| OpenShift GitOps | Hosts `banking-demo-acm-root` + ApplicationSets |
| CyberArk Conjur | `gitops/components/conjur` — source of truth for secrets |
| Jenkins + BuildConfigs | CI builds images; bumps east+west overlays |
| Hub Kiali (optional) | Multi-cluster view; secrets via `scripts/mesh/sync-kiali-multicluster-secrets.sh` |

## Bootstrap (do not apply until the cluster is ready)

```bash
# context must be named acm (or pass --context)
oc --context acm apply -f gitops/bootstrap/acm-root.yaml -n openshift-gitops

# After east/west join ACM and are labeled:
#   banking-demo/role=spoke
#   banking-demo/region=east|west
oc --context acm label managedcluster east \
  cluster.open-cluster-management.io/clusterset=banking-spokes \
  banking-demo/role=spoke banking-demo/region=east --overwrite
oc --context acm label managedcluster west \
  cluster.open-cluster-management.io/clusterset=banking-spokes \
  banking-demo/role=spoke banking-demo/region=west --overwrite
oc --context acm apply -k gitops/acm
```


## Kube context

Expected local kubeconfig context name: **`acm`**.
