# Red Hat Quay (acm)

Depends on ODF Multicloud Object Gateway (`ObjectBucketClaim` API).

## After Quay is Ready

1. Open the Quay route: `oc -n quay-enterprise get route -l quay-component=quay`
2. Create the first user (superuser) via the Quay UI.
3. Create organization `banking` and repositories `banking-service`, `api-gateway`.
4. Create a robot account with write on those repos; store credentials for Jenkins:

```bash
# Secret consumed by CI (create once; not GitOps'd — contains robot token)
oc -n banking-ci create secret docker-registry quay-ci \
  --docker-server="$(oc -n quay-enterprise get route banking-quay-quay -o jsonpath='{.spec.host}')" \
  --docker-username='banking+ci' \
  --docker-password='<robot-token>'
```

Pipelines push signed images, SBOMs, and attestations to `quay.<host>/banking/<app>:<tag>`.
