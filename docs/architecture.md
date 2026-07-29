# Architecture

## Overview

This demo targets three OpenShift clusters:

| Cluster | Role |
| --- | --- |
| **acm** | RHACM hub, CyberArk Conjur, Jenkins CI, hub Kiali multi-cluster |
| **east** / **west** | Spokes with OpenShift GitOps, ESO, OSSM 3.4 ambient, PostgreSQL, Keycloak, Spring apps |

Credentials are sourced from **CyberArk Conjur** on the hub via the **External Secrets Operator** on each cluster. Spring apps never talk to Conjur; they only mount Kubernetes Secrets that ESO materializes.

**Traffic failover ≠ data failover.** Mesh locality can send `banking-service` traffic to the peer spoke; each spoke keeps its own PostgreSQL and Keycloak issuer.

```mermaid
flowchart TB
  subgraph acmHub [Cluster acm]
    ACM[RHACM ApplicationSets]
    Conjur[CyberArk Conjur]
    Jenkins[Jenkins CI]
    KialiHub[Kiali multi-cluster]
  end

  subgraph eastSpoke [Cluster east]
    ArgoE[OpenShift GitOps]
    MeshE[OSSM 3.4 ambient]
    PGE[(PostgreSQL)]
    KCE[Keycloak]
    GWE[api-gateway]
    BSE[banking-service]
  end

  subgraph westSpoke [Cluster west]
    ArgoW[OpenShift GitOps]
    MeshW[OSSM 3.4 ambient]
    PGW[(PostgreSQL)]
    KCW[Keycloak]
    GWW[api-gateway]
    BSW[banking-service]
  end

  ACM --> ArgoE
  ACM --> ArgoW
  Conjur --> ESO_E[ESO east]
  Conjur --> ESO_W[ESO west]
  GWE --> BSE
  BSE --> PGE
  GWE --> KCE
  BSE --> KCE
  GWW --> BSW
  BSW --> PGW
  GWW --> KCW
  BSW --> KCW
  MeshE <-->|HBONE peering| MeshW
  Jenkins -->|newTag east+west| GitRepo[Git repository]
  GitRepo --> ArgoE
  GitRepo --> ArgoW
```

## Red Hat / catalog components

| Concern | Component |
| --- | --- |
| Container platform | Red Hat OpenShift |
| Multi-cluster | Red Hat Advanced Cluster Management (RHACM) |
| GitOps | OpenShift GitOps Operator (Argo CD) |
| Service mesh | OpenShift Service Mesh 3.4 (Sail, ambient, Istio ~1.30) |
| Secrets sync | External Secrets Operator for Red Hat OpenShift |
| Secrets backend | CyberArk Conjur OSS (Helm chart, GitOps Application on acm) |
| Identity (OIDC) | Red Hat build of Keycloak (`rhbk-operator`) — **per spoke** |
| Banking DB | [`registry.redhat.io/rhel10/postgresql-16`](https://catalog.redhat.com/en/software/containers/rhel10/postgresql-16/677d13af607921b4d74fca88) — **per spoke** |
| App runtime images | UBI 9 OpenJDK 21 |
| CI | Jenkins on acm via Helm + OpenShift BuildConfig |

## GitOps ownership

1. **acm:** [`gitops/bootstrap/acm-root.yaml`](../gitops/bootstrap/acm-root.yaml) → [`gitops/applications/acm`](../gitops/applications/acm) (Conjur, Jenkins, hub ESO, Kiali).
2. **RHACM:** [`gitops/acm`](../gitops/acm) Placement + ApplicationSet `banking-spoke-roots` generates Applications that sync `gitops/applications/{{east|west}}` to each ManagedCluster.
3. **Spoke waves (east/west):**
   - `0` platform operators (RHBK, ESO, Sail, GitOps)
   - `1` ESO operand
   - `2` mesh (Istio / CNI / ZTunnel / east-west GW / DestinationRule)
   - `3` `ClusterSecretStore` + app `ExternalSecret`s (Conjur URL → acm)
   - `4+` PostgreSQL, Keycloak, banking-service, api-gateway

Details: [secrets-management.md](secrets-management.md), [multi-cluster.md](multi-cluster.md).

## Security model

- Clients obtain an access token from the **local** Keycloak realm `banking`.
- **api-gateway** validates the JWT (`issuer-uri`) and proxies `/api/**` to **banking-service**.
- **banking-service** is also an OAuth2 resource server.
- Actuator health endpoints remain unauthenticated for probes.
- Database and admin passwords are not stored in Git; Conjur on acm is the source of truth.

## Mesh failover

- `banking-service` Service: `istio.io/global=true` + waypoint
- DestinationRule: `outlierDetection` + `localityLbSetting.failoverPriority: topology.istio.io/cluster`
- PostgreSQL / Keycloak Services stay local (no global label)

See [multi-cluster.md](multi-cluster.md) for the scale-to-zero demo.
