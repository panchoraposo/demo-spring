# Cluster east (spoke)

| Namespace | Contents |
| --- | --- |
| `openshift-gitops` | OpenShift GitOps (Applications from ACM ApplicationSet or spoke-root) |
| `external-secrets-operator` / `external-secrets` | ESO → Conjur on **acm** |
| `istio-system` / `istio-cni` / `ztunnel` | OSSM 3.4 ambient |
| `banking-db` | PostgreSQL 16 (local; not failed over) |
| _(hub)_ `trusted-profile-analyzer` | Shared Keycloak on **acm** (Route `sso`) + TPA/RHDA |
| `banking-apps` | api-gateway + banking-service (ambient + global Service) |
| `openshift-devspaces` | OpenShift Dev Spaces (Spring + RHDA → TPA on acm) |

Conjur, Jenkins, Quay, RHTAS, and TPA are **not** installed here (hub only).

## Prerequisites before sync

1. OpenShift GitOps Operator installed.
2. Set spoke Conjur URL: `gitops/components/external-secrets/overlays/east/env/conjur.env` (or your env overlay).
3. `scripts/sync-conjur-creds-to-spokes.sh` copied `conjur-creds` + CA from acm.
4. Mesh peering after west is up: `scripts/mesh/exchange-remote-secrets.sh`.

## Kube context

Expected local kubeconfig context name: **`east`**.
