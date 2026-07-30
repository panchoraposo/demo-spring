# Red Hat Quay (acm)

Depends on ODF Multicloud Object Gateway (`ObjectBucketClaim` API).

This demo disables Clair / mirror / HPA / monitoring so Quay fits a single-node hub.
`Available` may stay `False` even when the registry HTTP endpoint is healthy — that is expected.

## Bootstrap CI credentials

```bash
scripts/bootstrap-quay-ci.sh
```

Creates org `banking`, repos, robot `banking+ci`, and Secrets:

- `banking-ci/quay-ci` (robot username/password)
- `banking-ci/cosign-signing-key` (CI signing keypair)

## Manual UI path

1. Open the Quay route: `oc -n quay-enterprise get route -l quay-component=quay-app-route`
2. First user is created via `/api/v1/user/initialize` (see bootstrap script) when `FEATURE_USER_INITIALIZE` is set in `config-bundle.yaml`.
3. Organization `banking`, repositories `banking-service` / `api-gateway`, robot with write.

Pipelines push signed images, SBOMs, and attestations to `<quay-host>/banking/<app>:<tag>`.

## Validate sign + SBOM + Rekor

```bash
scripts/validate-quay-sign-rekor.sh banking-service <BUILD_NUMBER>
scripts/validate-quay-sign-rekor.sh api-gateway <BUILD_NUMBER>
```
