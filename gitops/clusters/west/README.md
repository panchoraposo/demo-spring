# Cluster west (spoke)

Mirror of [east](../east/README.md) with independent PostgreSQL + Keycloak and Dev Spaces.

| Overlay | Path |
| --- | --- |
| Apps | `gitops/applications/west` |
| banking-service | `gitops/components/banking-service/overlays/west` |
| api-gateway | `gitops/components/api-gateway/overlays/west` |
| Mesh | `gitops/components/mesh/overlays/west` |

Set `REPLACE_ME_WEST_APPS_DOMAIN` in the api-gateway west overlay issuer URI before relying on OIDC against west Keycloak.

## Kube context

Expected local kubeconfig context name: **`west`**.
