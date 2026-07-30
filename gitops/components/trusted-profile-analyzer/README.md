# Red Hat Trusted Profile Analyzer (acm)

## Dependencies

1. ODF Multicloud Object Gateway Ready (`ObjectBucketClaim` `tpa-storage`).
2. PostgreSQL Deployment in this folder (or external DB secrets).
3. OIDC issuer (RHBK / RH-SSO) with clients for TPA UI + CLI.
4. `rhtpa-operator` Subscription Succeeded.

## Create the TrustedProfileAnalyzer instance

The CRD is Technology Preview; field names vary by channel. Copy the operator’s
sample from the CSV / console, or start from
[`trustedprofileanalyzer.sample.yaml`](trustedprofileanalyzer.sample.yaml), then:

```bash
oc apply -f gitops/components/trusted-profile-analyzer/trustedprofileanalyzer.sample.yaml
```

## Wire ODF bucket credentials

```bash
NS=trusted-profile-analyzer
oc -n "$NS" get cm tpa-storage -o yaml
oc -n "$NS" get secret tpa-storage -o yaml
# Update Secret storage-credentials and TrustedProfileAnalyzer storage fields.
```

## Vulnerability importers

`TrustedProfileAnalyzer` seeds `osv-github`, `cve`, and `redhat-csaf` as enabled under
`spec.modules.createImporters.importers`. After install, Ansible also runs
`scripts/bootstrap-tpa-importers.sh` so sources stay enabled even if the create-importers
job first seeded them disabled.

Without these sources, uploaded SBOMs appear in TPA with empty advisory/vulnerability results
(RHDA in Dev Spaces still works because it queries external backends directly).

## RHDA ↔ Dev Spaces

```bash
oc -n trusted-profile-analyzer get route rhda-backend \
  -o jsonpath='https://{.spec.host}{"\n"}'
```

Set as `redhat.dependency.analytics.exhort.backendUrl` / `REPLACE_ME_RHDA_BACKEND_URL`.
