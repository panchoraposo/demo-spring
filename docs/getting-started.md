# Getting started

For the **acm / east / west** layout, follow [multi-cluster.md](multi-cluster.md) first (hub Conjur + Jenkins, spoke apps, mesh peering).

The steps below are the legacy **single-spoke east** path. After the multi-cluster cutover, Conjur/Jenkins are **not** on east — use acm bootstrap instead of `bootstrap-east.sh`.

## Prerequisites

- OpenShift 4.14+ with cluster-admin (ESO GA channels typically need a recent OCP; use `stable-v1` when available)
- `oc` logged into the target cluster (**acm** for hub, **east**/**west** for spokes)
- Cluster pull secret able to pull from `registry.redhat.io` and Docker Hub (Conjur / nginx / postgres ImageStreams, or mirror them)
- This repository pushed to a Git remote reachable by OpenShift GitOps and Jenkins

## 1. Set placeholders and push

```bash
export GIT_REPO_URL="https://github.com/<org>/demo-spring.git"
export CLUSTER_DOMAIN="apps.east.example.com"   # oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'

./scripts/set-placeholders.sh
git add -A && git commit -m "chore: set east cluster placeholders" && git push
```

## 2. Bootstrap GitOps root app

```bash
export GIT_REPO_URL CLUSTER_DOMAIN
./scripts/bootstrap-east.sh
```

Watch Applications:

```bash
oc get applications -n openshift-gitops
oc get route -n openshift-gitops
```

## 3. Verify secrets stack, then workloads

```bash
# Conjur + External Secrets (see docs/secrets-management.md)
oc get pods -n banking-conjur
oc get job -n banking-conjur
oc get pods -n external-secrets
oc get clustersecretstore conjur-backend
oc get externalsecret -A

# Application namespaces
oc get pods -n banking-db
oc get pods -n banking-idp
oc get keycloak -n banking-idp
oc get pods -n banking-ci
oc get pods -n banking-apps
```

If the Conjur bootstrap Job fails, delete it and refresh Application `conjur-config`:

```bash
oc -n banking-conjur delete job conjur-bootstrap --ignore-not-found
oc -n openshift-gitops annotate application conjur-config argocd.argoproj.io/refresh=hard --overwrite
```

PostgreSQL uses the catalog image `registry.redhat.io/rhel10/postgresql-16`. Credentials come from Conjur via External Secrets (not from Git).

## 4. Build application images (first time)

Prefer Jenkins jobs (see [ci-cd.md](ci-cd.md)): `banking-service-ci` and `api-gateway-ci` in the Jenkins UI. They poll Git for path changes and push ImageStream tags, then bump GitOps `newTag`.

Configure Secret `banking-ci/github-ci` (via Conjur `banking/github-ci/token`) with a GitHub PAT so the GitOps commit stage can push.

Manual image build without Jenkins:

```bash
oc -n banking-apps start-build banking-service --from-dir=apps/banking-service --follow
oc -n banking-apps start-build api-gateway --from-dir=apps/api-gateway --follow
```

## 5. Obtain a JWT and call APIs

```bash
KEYCLOAK_URL="https://keycloak-banking.${CLUSTER_DOMAIN}"
GATEWAY_URL="https://$(oc get route api-gateway -n banking-apps -o jsonpath='{.spec.host}')"

TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/realms/banking/protocol/openid-connect/token" \
  -d "client_id=banking-cli" \
  -d "username=teller" \
  -d "password=teller-change-me" \
  -d "grant_type=password" | jq -r .access_token)

curl -s -H "Authorization: Bearer ${TOKEN}" \
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

## 6. Local development (optional)

```bash
# Start PostgreSQL locally or port-forward
oc -n banking-db port-forward svc/postgresql 5432:5432

cd apps/banking-service
mvn spring-boot:run
```

Set `OIDC_ISSUER_URI` to your Keycloak realm issuer when testing security locally.
