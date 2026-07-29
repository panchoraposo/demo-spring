# Cluster east (spoke)

| Namespace | Contents |
| --- | --- |
| `openshift-gitops` | OpenShift GitOps (Applications from ACM ApplicationSet or spoke-root) |
| `external-secrets-operator` / `external-secrets` | ESO → Conjur on **acm** |
| `istio-system` / `istio-cni` / `ztunnel` | OSSM 3.4 ambient |
| `banking-db` | PostgreSQL 16 (local; not failed over) |
| `banking-idp` | Red Hat build of Keycloak (local issuer) |
| `banking-apps` | api-gateway + banking-service (ambient + global Service) |

Conjur and Jenkins are **not** installed here (hub only).

## Prerequisites before sync

1. OpenShift GitOps Operator installed.
2. `REPLACE_ME_ACM_APPS_DOMAIN` set in spoke `ClusterSecretStore` (commit or sed).
3. `scripts/sync-conjur-creds-to-spokes.sh` copied `conjur-creds` + CA from acm.
4. Mesh peering after west is up: `scripts/mesh/exchange-remote-secrets.sh`.

## Kube context

Expected local kubeconfig context name: **`east`**.
