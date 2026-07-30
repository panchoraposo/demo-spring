# Cluster west (managed)

Mirror of [east](../east/README.md) with independent PostgreSQL.

| Overlay | Path |
| --- | --- |
| Apps | `gitops/applications/west` |
| banking-service | `gitops/components/banking-service/overlays/west` |
| api-gateway | `gitops/components/api-gateway/overlays/west` |
| Mesh | `gitops/components/mesh/overlays/west` |

OIDC uses the shared Keycloak on **acm** (`banking-idp` Route `sso`).

## Kube context

Expected local kubeconfig context name: **`west`**.
