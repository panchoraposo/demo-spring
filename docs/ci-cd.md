# CI/CD

## Design

Jenkins and BuildConfigs run on hub cluster **acm**. Builds resolve Maven dependencies through **Nexus** (`maven-public` = Maven Central + Red Hat GA). After the image build, pipelines push to **Red Hat Quay**, generate an **SBOM**, **sign/attest** with **RHTAS**, then run **ACS in series** (`image scan` CVEs, then `image check` policies) before GitOps promotion.

| Stage | Tool | Responsibility |
| --- | --- | --- |
| Detect change | Gitea push webhook + SCM poll (path-filtered) | Fire only the app pipeline whose paths changed |
| Checkout | Jenkins on acm | Fetch source from **Gitea** (`banking/demo-spring`) |
| Image build | OpenShift BuildConfig on acm | Docker build uses `settings.xml` → Nexus; ImageStream tag |
| Mirror + supply chain | `ci/scripts/sign-and-attest.sh` | Push to Quay; Syft SBOM; cosign attach/attest/sign (RHTAS) |
| ACS | `acs-image-scan.sh` then `acs-image-check.sh` | CVEs first; Critical CVE aborts before policies / GitOps |
| GitOps | Jenkins | Commit `newTag` (+ Quay `newName`) in east **and** west overlays |
| Deploy | OpenShift GitOps on managed clusters | Sync Applications → Deployments |

### Dev Spaces ← Gitea → Jenkins (CVE demo)

SCM for CI is **Gitea on acm** (not GitHub). Inner-loop fix of Critical CVEs:

```bash
# One-time on the hub: Route + cert so Dev Spaces can fetch via raw.<gitea-host>
./scripts/bootstrap-devspaces-gitea-raw.sh

# Factory URL (opens the Gitea repo in Dev Spaces)
./scripts/print-devspaces-gitea-factory.sh

# One-time: Gitea push → Jenkins notifyCommit
./scripts/bootstrap-gitea-jenkins-webhook.sh
```

1. Open the factory URL → workspace clones `https://gitea.<apps>/banking/demo-spring.git`.
   - Git `user.name` / `user.email` are pre-set (`Demo Developer` / `demo@banking.local`).
   - If TLS fails on `raw.gitea.…`, re-run `bootstrap-devspaces-gitea-raw.sh`, or use the
     script’s **Fallback (rawdevfile)** URL / “Continue with default devfile”.
2. Edit `apps/banking-service/pom.xml` (e.g. `<tomcat.version>10.1.35</tomcat.version>`).
3. Commit and push to `main` (Git credentials: Gitea user `git` / `BankingGitCiChangeMe!` or a PAT).
4. Jenkins `banking-service-ci` runs (webhook, or SCM poll within ~1 minute).

Short demo hosts (acm): `gitea`, `jenkins`, `nexus`, `conjur`, `rhda`, `sso`, `devspaces`.
Spokes: `gateway`, `si-gateway` (plus `keycloak-banking`).

### Maven / Nexus

| Consumer | How |
| --- | --- |
| OpenShift builds | `apps/*/settings.xml` (+ `ci/maven/settings.xml`) → `http://nexus.nexus.svc.cluster.local:8081/repository/maven-public/` |
| Dev Spaces | `devfile.yaml` runs `mvn -s ci/maven/settings.xml …` |
| Laptop | `./scripts/generate-maven-settings.sh > ~/.m2/settings.xml` (uses the Nexus Route) |

Bootstrap repos after Nexus is Ready: `./scripts/bootstrap-nexus.sh`.

### Maven cache (fast CI)

Jenkins runs **`Maven package`** on the controller with a persistent
`${JENKINS_HOME}/.m2/repository` (PVC). The OpenShift Build only copies the jar
(`Dockerfile`) — no Maven download inside the build pod. Use `Dockerfile.full`
for a self-contained local/image build.

Warm once after Nexus is Ready (or after big POM changes):

```bash
./scripts/warm-nexus-maven.sh
```

### ACS (Central + east/west Sensors + CI gate)

```bash
# Sensors on managed clusters → Central on acm
./scripts/bootstrap-acs-secured-clusters.sh

# API token → banking-ci/acs-ci (Jenkins JCasC credentials acs-ci-token / acs-central-url)
# Cosign public key → ACS Signature Integration (Verified badge in the portal)
./scripts/bootstrap-acs-signature-integration.sh
./scripts/bootstrap-acs-ci.sh
oc --context acm -n banking-ci delete pod jenkins-0   # reload env into JCasC
```

ACS is one Jenkins stage with two sequential steps (CVEs first). A Critical CVE
fails the stage immediately so policies and GitOps do not run:

| Step | CLI | Gate |
| --- | --- | --- |
| 1. Vulnerabilities | `roxctl image scan` | `ACS_SCAN_FAIL_ON` (default `Critical`) |
| 2. Policies | `roxctl image check` | `ACS_FAIL_ON` (default `Critical`) |

Both require Central (`ACS_REQUIRED=true`). Scripts: `ci/scripts/acs-image-scan.sh`, `ci/scripts/acs-image-check.sh`.

Jenkins does **not** `oc apply` app manifests. GitOps owns cluster state.

```mermaid
sequenceDiagram
  participant Dev as Developer
  participant Git as Git repo
  participant J as Jenkins on acm
  participant BC as BuildConfig
  participant Nexus as Nexus on acm
  participant Quay as Quay on acm
  participant TAS as RHTAS
  participant ACS as ACS Central
  participant ArgoE as GitOps east
  participant ArgoW as GitOps west

  Dev->>Git: push apps/banking-service/**
  J->>Git: SCM poll
  J->>BC: oc start-build --from-dir
  BC->>Nexus: mvn deps (maven-public)
  BC-->>J: ImageStream tag BUILD_NUMBER
  J->>Quay: mirror image
  J->>J: syft SBOM
  J->>TAS: cosign sign + attest (Rekor)
  Quay-->>Quay: image + sbom + .sig + .att
  J->>ACS: roxctl image scan (CVEs)
  ACS-->>J: pass / fail
  J->>ACS: roxctl image check (policies)
  ACS-->>J: pass / fail
  J->>Git: commit newTag/newName on east+west
  ArgoE->>Git: refresh
  ArgoW->>Git: refresh
```

## Quay artifacts

For each build, Quay org `banking` should contain:

| Artifact | How |
| --- | --- |
| Image | `skopeo`/`oc image mirror` from ImageStream |
| SBOM | `cosign attach sbom` (CycloneDX) |
| Attestation | `cosign attest --type cyclonedx` (`.att`) |
| Signature | `cosign sign` (`.sig`, Rekor via RHTAS) |

Inspect with `cosign tree <quay-host>/banking/<app>:<tag>`.

## Jenkins jobs

Defined via JCasC Job DSL in [`gitops/components/jenkins/helm-values.yaml`](../gitops/components/jenkins/helm-values.yaml):

| Job | Jenkinsfile | Polls paths |
| --- | --- | --- |
| `banking-service-ci` | [`ci/Jenkinsfile.banking-service`](../ci/Jenkinsfile.banking-service) | `apps/banking-service/**` |
| `api-gateway-ci` | [`ci/Jenkinsfile.api-gateway`](../ci/Jenkinsfile.api-gateway) | `apps/api-gateway/**` |

SCM poll interval: every ~3 minutes (`H/3 * * * *`). Manual **Build with Parameters** (`FORCE_BUILD=true`) always builds.

## Credentials (acm `banking-ci`)

| Secret / Jenkins id | Purpose |
| --- | --- |
| `github-ci` | GitOps push PAT |
| `quay-ci` | Quay robot (`username` / `password`) |
| `cosign-signing-key` | PEM in key `cosign.key` for non-interactive signing |
| `tpa-oidc-cli` | OIDC client secret for uploading SBOMs to TPA |

Without Quay/cosign, the OpenShift build still succeeds; the sign stage is skipped with a warning.

```bash
oc -n banking-ci create secret generic quay-ci \
  --from-literal=username='banking+ci' \
  --from-literal=password='<robot-token>'
oc -n banking-ci create secret generic cosign-signing-key \
  --from-file=cosign.key=./cosign.key
```

## Image BuildConfigs

Binary Docker BuildConfigs in acm `banking-apps` (synced from [`ci/buildconfig/`](../ci/buildconfig/)):

- `banking-service`
- `api-gateway`

## Image tags / Quay promotion

Overlays under `gitops/components/<app>/overlays/{east,west}/kustomization.yaml`:

```yaml
images:
  - name: image-registry.openshift-image-registry.svc:5000/banking-apps/<app>
    newName: <quay-host>/banking/<app>   # set by pipeline after sign
    newTag: <BUILD_NUMBER>
```

Managed clusters need pull access to Quay. After `scripts/bootstrap-quay-ci.sh`, run:

```bash
scripts/sync-quay-pull-secret-to-clusters.sh
# creates banking-apps/quay-pull on east/west (also done by Ansible install)
```
