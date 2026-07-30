# Cluster west (spoke)

Mirror of [east](../east/README.md) with independent PostgreSQL and Dev Spaces.

| Overlay | Path |
| --- | --- |
| Apps | `gitops/applications/west` |
| banking-service | `gitops/components/banking-service/overlays/west` |
| api-gateway | `gitops/components/api-gateway/overlays/west` |
| Mesh | `gitops/components/mesh/overlays/west` |

OIDC uses the shared Keycloak on **acm** (Route `trusted-profile-analyzer/sso`).

## Kube context

Expected local kubeconfig context name: **`west`**.
