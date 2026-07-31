# Red Hat Advanced Cluster Security (RHACS)

Central + SecuredCluster on **acm** (`namespace/stackrox`).

## After sync

```bash
# Central UI
oc --context acm -n stackrox get route central -o jsonpath='https://{.spec.host}{"\n"}'

# Initial admin password (operator-generated)
oc --context acm -n stackrox get secret central-htpasswd \
  -o jsonpath='{.data.password}' | base64 -d; echo

# Create a CI API token and seed Conjur / banking-ci Secret:
./scripts/bootstrap-acs-ci.sh
```

Jenkins stage `ACS image check` runs `roxctl image check` against Quay images
after sign/attest and before GitOps promotion.
