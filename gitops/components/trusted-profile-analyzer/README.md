# Red Hat Trusted Profile Analyzer (acm)

## Dependencies

1. ODF Multicloud Object Gateway Ready (`ObjectBucketClaim` `tpa-storage`).
2. PostgreSQL Deployment in this folder (or external DB secrets).
3. OIDC issuer (RHBK / RH-SSO) with clients for TPA UI + CLI.

## Wire ODF bucket credentials

```bash
NS=trusted-profile-analyzer
# After OBC is Bound:
oc -n "$NS" get cm tpa-storage -o yaml
oc -n "$NS" get secret tpa-storage -o yaml

# Update Secret storage-credentials (user/password) and TrustedProfileAnalyzer
# spec.storage.endpoint / bucket from the OBC ConfigMap fields.
```

## RHDA ↔ Dev Spaces

After the `rhda-backend` Route is admitted:

```bash
oc -n trusted-profile-analyzer get route rhda-backend \
  -o jsonpath='https://{.spec.host}{"\n"}'
```

Set that URL as `redhat.dependency.analytics.exhort.backendUrl` in the repo
`.vscode/settings.json` (and Dev Spaces CheCluster default components).
