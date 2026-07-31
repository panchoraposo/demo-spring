# Supply chain (ODF, Quay, RHTAS, TPA, Dev Spaces)

Prep manifests for hub supply-chain services and developer workspaces. **Do not apply** until acm/east/west are ready.

## Hub (acm)

| Component | Path | Notes |
| --- | --- | --- |
| OpenShift Data Foundation | `gitops/components/odf` | MCG/NooBaa standalone → `ObjectBucketClaim` |
| Red Hat Quay | `gitops/components/quay` | Managed `objectstorage` via ODF |
| Trusted Artifact Signer | `gitops/components/trusted-artifact-signer` | Securesign (Fulcio/Rekor/TUF/TSA) |
| Trusted Profile Analyzer | `gitops/components/trusted-profile-analyzer` | Advisories + RHDA backend |
| Advanced Cluster Security | `gitops/components/rhacs` | Central + SecuredCluster on acm |
| Nexus Repository Manager | `gitops/components/nexus` | Maven Central + Red Hat GA group |

Operators: [`gitops/platform/operators-hub`](../gitops/platform/operators-hub) (RHACS Subscription). Nexus is a Deployment (no OLM).

### Bootstrap order

1. Platform operators (wave 0) including `odf-operator`, `quay-operator`, `rhtas-operator`, `rhtpa-operator`, `rhacs-operator`.
2. ODF `StorageCluster` MCG-only — wait until `openshift-storage.noobaa.io` StorageClass exists.
3. QuayRegistry + Securesign + RHACS Central.
4. Nexus Deployment → `./scripts/bootstrap-nexus.sh` (repos + anonymous read).
5. TPA PostgreSQL + `rhda-backend` + Keycloak SSO (GitOps managed; secrets via Conjur/ESO).
6. ACS CI token: `./scripts/bootstrap-acs-ci.sh` → `banking-ci/acs-ci` for Jenkins.
7. Optional values:
   - Fulcio OIDC issuer for RHTAS (`gitops/components/trusted-artifact-signer/env/rhtas.env`)
   - RHDA/TPA URLs for Dev Spaces (`devfile.yaml` / CheCluster overlays)

### TPA post-install (vulnerability importers)

SBOM upload alone does not show CVEs until advisory sources are ingested. Install enables:

- GitOps: `modules.createImporters.importers` in [`trustedprofileanalyzer.yaml`](../gitops/components/trusted-profile-analyzer/trustedprofileanalyzer.yaml) (`osv-github`, `cve`, `redhat-csaf`)
- Ansible: `bootstrap_tpa_importers` → [`scripts/bootstrap-tpa-importers.sh`](../scripts/bootstrap-tpa-importers.sh) (idempotent API enable after TPA/SSO are up)

First sync of OSV/CVE/CSAF can take a long time on small hubs.

### Quay post-install

See [`gitops/components/quay/README.md`](../gitops/components/quay/README.md): create org `banking`, repos, robot; store `quay-ci` in `banking-ci`.

### RHTAS signing

- Interactive / keyless: configure Fulcio OIDC issuer, then `cosign sign` with OIDC.
- CI (Jenkins): cosign key in `cosign-signing-key` + Rekor URL from the Securesign instance (`ci/scripts/sign-and-attest.sh`).

## Dev Spaces (hub)

| Component | Path |
| --- | --- |
| Dev Spaces operator | `gitops/platform/operators-hub/subscription-devspaces.yaml` |
| CheCluster | `gitops/components/devspaces/overlays/acm` |

### Default Spring workspace

Opening this Git repo in Dev Spaces loads:

- [`devfile.yaml`](../devfile.yaml) — UDI + Maven/Spring commands using **Nexus** (`ci/maven/settings.xml`)
- [`.vscode/extensions.json`](../.vscode/extensions.json) — Java, Spring Boot, **Red Hat Dependency Analytics** (`redhat.fabric8-analytics`)
- [`.vscode/settings.json`](../.vscode/settings.json) — `redhat.dependency.analytics.exhort.backendUrl` → acm `rhda-backend` Route (private TPA)

Laptop Maven (outside the cluster):

```bash
./scripts/generate-maven-settings.sh > ~/.m2/settings.xml
mvn -f apps/banking-service/pom.xml -DskipTests package
```

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
# acm → "Hub Cluster"; east → "East Cluster"; west → "West Cluster"
scripts/apply-console-links.sh
# ApplicationMenu links (Gitea, Jenkins, Quay, Rekor, Kiali)
```
