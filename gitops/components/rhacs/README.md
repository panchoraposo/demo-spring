# Red Hat Advanced Cluster Security (RHACS)

- **acm**: Central + hub SecuredCluster (`gitops/components/rhacs`)
- **east / west**: SecuredCluster Sensors (`gitops/components/rhacs-secured`) → Central Route on acm

## After sync

```bash
# Central UI
oc --context acm -n stackrox get route central -o jsonpath='https://{.spec.host}{"\n"}'

# Initial admin password (operator-generated)
oc --context acm -n stackrox get secret central-htpasswd \
  -o jsonpath='{.data.password}' | base64 -d; echo

# Register managed clusters (operator + CRS/init-bundle + SecuredCluster)
./scripts/bootstrap-acs-secured-clusters.sh

# Create a CI API token → banking-ci/acs-ci (Jenkins credentials)
./scripts/bootstrap-acs-ci.sh
# Restart Jenkins once so JCasC picks up ACS_API_TOKEN / ACS_CENTRAL_URL:
#   oc --context acm -n banking-ci delete pod jenkins-0
```

Jenkins stage `ACS image check` runs `roxctl image check` against Quay images
after sign/attest and before GitOps promotion.
