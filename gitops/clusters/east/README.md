# Cluster east (managed)

| Namespace | Contents |
| --- | --- |
| `openshift-gitops` | OpenShift GitOps (Applications from ACM ApplicationSet) |
| `external-secrets-operator` / `external-secrets` | ESO → Conjur on **acm** |
| `istio-system` / `istio-cni` / `ztunnel` | OSSM 3.4 ambient |
| `banking-db` | PostgreSQL 16 (local; not failed over) |
| `banking-apps` | api-gateway + banking-service (ambient + global Service) |

Conjur, Keycloak, Jenkins, Quay, RHTAS, TPA, and Dev Spaces are **not** installed here (hub only).

OIDC uses shared Keycloak on **acm** (`banking-idp` Route `sso`).

## Prerequisites before sync

1. OpenShift GitOps Operator installed (via managed operators wave).
2. Set Conjur URL: `gitops/components/external-secrets/overlays/east/env/conjur.env` (or run Ansible `configure_environment`).
3. `scripts/sync-conjur-creds-to-clusters.sh` copied `conjur-creds` + CA from acm.
4. Quay pull secret: `scripts/sync-quay-pull-secret-to-clusters.sh` → `banking-apps/quay-pull`.
5. Mesh peering after west is up: `scripts/mesh/exchange-remote-secrets.sh`.

## Kube context

Expected local kubeconfig context name: **`east`**.
