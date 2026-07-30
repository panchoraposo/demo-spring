# Supply chain (ODF, Quay, RHTAS, TPA, Dev Spaces)

Prep manifests for hub supply-chain services and spoke developer workspaces. **Do not apply** until acm/east/west are ready.

## Hub (acm)

| Component | Path | Notes |
| --- | --- | --- |
| OpenShift Data Foundation | `gitops/components/odf` | MCG/NooBaa standalone → `ObjectBucketClaim` |
| Red Hat Quay | `gitops/components/quay` | Managed `objectstorage` via ODF |
| Trusted Artifact Signer | `gitops/components/trusted-artifact-signer` | Securesign (Fulcio/Rekor/TUF/TSA) |
| Trusted Profile Analyzer | `gitops/components/trusted-profile-analyzer` | Advisories + RHDA backend |

Operators: [`gitops/platform/operators-hub`](../gitops/platform/operators-hub).

### Bootstrap order

1. Platform operators (wave 0) including `odf-operator`, `quay-operator`, `rhtas-operator`, `rhtpa-operator`.
2. ODF `StorageCluster` MCG-only — wait until `openshift-storage.noobaa.io` StorageClass exists.
3. QuayRegistry + Securesign.
4. TPA PostgreSQL + `rhda-backend` + Keycloak SSO (GitOps managed; secrets via Conjur/ESO).
5. Optional values:
   - Fulcio OIDC issuer for RHTAS (`gitops/components/trusted-artifact-signer/env/rhtas.env`)
   - RHDA/TPA URLs for Dev Spaces (`devfile.yaml` / CheCluster overlays)

### Quay post-install

See [`gitops/components/quay/README.md`](../gitops/components/quay/README.md): create org `banking`, repos, robot; store `quay-ci` in `banking-ci`.

### RHTAS signing

- Interactive / keyless: configure Fulcio OIDC issuer, then `cosign sign` with OIDC.
- CI (Jenkins): cosign key in `cosign-signing-key` + Rekor URL from the Securesign instance (`ci/scripts/sign-and-attest.sh`).

## Spokes (east / west)

| Component | Path |
| --- | --- |
| Dev Spaces operator | `gitops/platform/operators-spoke/subscription-devspaces.yaml` |
| CheCluster | `gitops/components/devspaces` |

### Default Spring workspace

Opening this Git repo in Dev Spaces loads:

- [`devfile.yaml`](../devfile.yaml) — UDI + Maven/Spring commands
- [`.vscode/extensions.json`](../.vscode/extensions.json) — Java, Spring Boot, **Red Hat Dependency Analytics** (`redhat.fabric8-analytics`)
- [`.vscode/settings.json`](../.vscode/settings.json) — `redhat.dependency.analytics.exhort.backendUrl` → acm `rhda-backend` Route (private TPA)

```bash
# On acm, after TPA/RHDA is up:
oc -n trusted-profile-analyzer get route rhda-backend \
  -o jsonpath='https://{.spec.host}{"\n"}'
# Paste into REPLACE_ME_RHDA_BACKEND_URL (repo + CheCluster env).

# Optional: TPA server route (UI/API). Use as TPA_URL.
oc -n trusted-profile-analyzer get route -l app.kubernetes.io/component=server \
  -o jsonpath='https://{.items[0].spec.host}{"\n"}'
# Paste into REPLACE_ME_TPA_URL.
```

## Console banner

```bash
scripts/apply-console-banners.sh
# acm → "Hub Cluster"; east/west unchanged
```
