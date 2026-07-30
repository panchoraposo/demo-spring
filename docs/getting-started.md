# Getting started

For the **acm / east / west** layout, follow [multi-cluster.md](multi-cluster.md) and the [Ansible installer](../ansible/README.md).

## Prerequisites

- OpenShift 4.14+ with cluster-admin on acm, east, and west
- `oc` contexts named **`acm`**, **`east`**, **`west`**
- RHACM hub with east/west joined as Available ManagedClusters
- `istioctl`, `jq`, `curl`, `openssl`, `python3`, `ansible-core`
- This repository (or a fork/branch) reachable by OpenShift GitOps and Jenkins

## Install

```bash
cd ansible
cp inventory.example.yml inventory.yml
# Point git_repo_url / git_target_revision at your env-specific remote
ansible-playbook -i inventory.yml playbooks/install.yml
```

Watch Applications:

```bash
oc --context acm get applications -n openshift-gitops
oc --context east get applications -n openshift-gitops
oc --context west get applications -n openshift-gitops
```

## Verify secrets stack and workloads

```bash
# Hub Conjur + Keycloak + TPA
oc --context acm get pods -n banking-conjur
oc --context acm get pods -n banking-idp
oc --context acm get pods -n trusted-profile-analyzer
oc --context acm get secret conjur-creds -n external-secrets

# Managed clusters
oc --context east get clustersecretstore conjur-backend
oc --context east get pods -n banking-db
oc --context east get pods -n banking-apps
oc --context west get pods -n banking-apps
```

If the Conjur bootstrap Job fails:

```bash
oc --context acm -n banking-conjur delete job conjur-bootstrap --ignore-not-found
oc --context acm -n openshift-gitops annotate application conjur-config argocd.argoproj.io/refresh=hard --overwrite
```

## Obtain a JWT and call APIs

```bash
KEYCLOAK_URL="https://$(oc --context acm -n banking-idp get route sso -o jsonpath='{.spec.host}')"
GATEWAY_URL="https://$(oc --context east -n banking-apps get route api-gateway -o jsonpath='{.spec.host}')"

TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/banking/protocol/openid-connect/token" \
  -d "client_id=banking-cli" \
  -d "username=teller" \
  -d "password=teller-change-me" \
  -d "grant_type=password" | jq -r .access_token)

curl -sk -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"firstName":"Ada","lastName":"Lovelace","email":"ada@bank.demo","nationalId":"NID-001"}' \
  "${GATEWAY_URL}/api/v1/customers"
```

Default demo credentials (change immediately outside workshops):

| Item | Value |
| --- | --- |
| Keycloak admin | `admin` / `admin-change-me` |
| Demo user | `teller` / `teller-change-me` |
| Public client | `banking-cli` |
| DB user/password | `banking` / `banking-demo-change-me` |
| Jenkins admin | `admin` / `ChangeMeOnFirstLogin!` |

The hub credentials dashboard (`namespace/dashboard`) lists live Routes and defaults after install.

## First CI images

Prefer Jenkins jobs (see [ci-cd.md](ci-cd.md)): `banking-service-ci` and `api-gateway-ci`. Configure Conjur/GitHub PAT so the GitOps commit stage can push (`scripts/set-conjur-github-pat.sh`).

## Local development (optional)

```bash
oc --context east -n banking-db port-forward svc/postgresql 5432:5432
```

See [api-reference.md](api-reference.md) for the full API surface.
