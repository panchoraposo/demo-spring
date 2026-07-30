# Conjur PAT automation + secret sync demo

## GitHub CI PAT in Conjur

Jenkins pushes GitOps commits with credential id `github-ci`, synced from Conjur:

| Conjur variable | Value |
| --- | --- |
| `banking/github-ci/username` | GitHub login (e.g. `panchoraposo`) |
| `banking/github-ci/token` | GitHub PAT / fine-grained token with **contents: write** on `panchoraposo/demo-spring` |

ESO syncs Secret `banking-ci/github-ci` → Jenkins credential id `github-ci`.

### Load / rotate PAT (automated)

```bash
# From env:
export GITHUB_TOKEN=<pat>
export GITHUB_USERNAME=panchoraposo
scripts/set-conjur-github-pat.sh

# Or reuse macOS/git credential helper for github.com:
GITHUB_USERNAME=panchoraposo scripts/set-conjur-github-pat.sh
```

What it does:

1. Validates the PAT against `https://api.github.com/repos/panchoraposo/demo-spring` (read + push)
2. Writes `banking/github-ci/{username,token}` in Conjur on **acm**
3. Forces `ExternalSecret/github-ci` reconcile → Secret `banking-ci/github-ci`
4. Restarts Jenkins so JCasC reloads credential id `github-ci`

Optional Gitea mode: `GIT_PROVIDER=gitea GITEA_TOKEN=... scripts/set-conjur-github-pat.sh`.

## Demo: change Conjur → ESO syncs K8s Secret

Hub (always available after bootstrap):

```bash
scripts/demo-conjur-secret-sync.sh
```

Default path: `banking/jenkins/jenkins-admin-password` → `banking-ci/jenkins-admin`.

Spoke banking-service password (after `scripts/sync-conjur-creds-to-spokes.sh` and apps synced):

```bash
VARIABLE=banking/banking-service/SPRING_DATASOURCE_PASSWORD \
CONTEXT=east NAMESPACE=banking-apps SECRET=banking-service-db \
KEY=SPRING_DATASOURCE_PASSWORD \
scripts/demo-conjur-secret-sync.sh
```

Apps never call Conjur; only ESO materializes Secrets (`refreshInterval` is 1h — the script force-annotates the ExternalSecret for immediate sync).

## Quay CI bootstrap + sign/attest validation

```bash
# After ODF MCG is Ready and QuayRegistry Available:
scripts/bootstrap-quay-ci.sh

# Re-run Jenkins jobs, then:
scripts/validate-quay-sign-rekor.sh banking-service <BUILD_NUMBER>
scripts/validate-quay-sign-rekor.sh api-gateway <BUILD_NUMBER>
```

### Manual Rekor / SBOM checks

```bash
export REKOR_URL=$(oc --context acm -n trusted-artifact-signer get rekor -o jsonpath='{.items[0].status.url}')
export QUAY_HOST=$(oc --context acm -n quay-enterprise get route -l quay-component=quay-app-route -o jsonpath='{.items[0].spec.host}')
export IMAGE="${QUAY_HOST}/banking/banking-service:<tag>"

# Pull cosign.pub from CI secret
oc --context acm -n banking-ci get secret cosign-signing-key -o jsonpath='{.data.cosign\.pub}' | base64 -d > cosign.pub

cosign tree "${IMAGE}"
cosign verify --key cosign.pub --rekor-url="${REKOR_URL}" "${IMAGE}"
cosign verify-attestation --type cyclonedx --key cosign.pub --rekor-url="${REKOR_URL}" "${IMAGE}"

# UUID printed by verify → fetch entry
rekor-cli --rekor_server "${REKOR_URL}" get --uuid <uuid>
```
