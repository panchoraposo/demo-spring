# Cluster east

Current demo target. All Applications under [`../applications/east`](../applications/east) deploy here.

| Namespace | Contents |
| --- | --- |
| `openshift-gitops` | OpenShift GitOps + root/child Applications |
| `external-secrets-operator` | ESO Operator Subscription |
| `external-secrets` | ESO operand controllers |
| `banking-vault` | HashiCorp Vault + bootstrap Job + UI Route |
| `banking-db` | PostgreSQL 16 (catalog image); secrets from ESO |
| `banking-idp` | Red Hat build of Keycloak; secrets from ESO |
| `banking-apps` | api-gateway + banking-service |
| `banking-ci` | Jenkins + pipeline BuildConfig |
| `rhbk-operator` | RHBK Operator subscription |

West and ACM placements will be added in a later iteration.
