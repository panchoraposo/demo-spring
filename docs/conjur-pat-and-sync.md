# Conjur PAT automation + secret sync demo

## Gitea CI PAT in Conjur (automatic)

`scripts/bootstrap-acm.sh` installs Gitea on **acm**, seeds `banking/demo-spring` (Spring apps + GitOps), creates a CI user PAT, and writes it to Conjur:

| Conjur variable | Value |
| --- | --- |
| `banking/github-ci/username` | `git` (Gitea CI user) |
| `banking/github-ci/token` | Gitea PAT (`write:repository`) |

ESO syncs Secret `banking-ci/github-ci` → Jenkins credential id `github-ci`.

Re-run seed only:

```bash
scripts/bootstrap-gitea.sh seed
```

## Rotate / override PAT manually

```bash
export GITEA_TOKEN=<pat>
export GITEA_USERNAME=git
scripts/set-conjur-github-pat.sh
```

What it does:

1. Writes `banking/github-ci/{username,token}` in Conjur on **acm**
2. Forces `ExternalSecret/github-ci` reconcile → Secret `banking-ci/github-ci`
3. Restarts Jenkins so JCasC reloads credential id `github-ci`

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
export QUAY_HOST=$(oc --context acm -n quay-enterprise get route -l quay-component=quay -o jsonpath='{.items[0].spec.host}')
export IMAGE="${QUAY_HOST}/banking/banking-service:<tag>"

# Pull cosign.pub from CI secret
oc --context acm -n banking-ci get secret cosign-signing-key -o jsonpath='{.data.cosign\.pub}' | base64 -d > cosign.pub

cosign tree "${IMAGE}"
cosign verify --key cosign.pub --rekor-url="${REKOR_URL}" "${IMAGE}"
cosign verify-attestation --type cyclonedx --key cosign.pub --rekor-url="${REKOR_URL}" "${IMAGE}"

# UUID printed by verify → fetch entry
rekor-cli --rekor_server "${REKOR_URL}" get --uuid <uuid>
```
