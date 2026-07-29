#!/usr/bin/env bash
# Copy Conjur ESO host credentials + TLS CA from acm to east/west.
# Run after conjur-bootstrap succeeds on acm.
set -euo pipefail

HUB_CONTEXT="${HUB_CONTEXT:-acm}"
SPOKE_CONTEXTS="${SPOKE_CONTEXTS:-east west}"

TMPDIR_SYNC="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_SYNC}"' EXIT

echo "==> Reading conjur-creds and CA from ${HUB_CONTEXT}"
oc --context "${HUB_CONTEXT}" -n external-secrets get secret conjur-creds \
  -o jsonpath='{.data.hostid}' > "${TMPDIR_SYNC}/hostid.b64"
oc --context "${HUB_CONTEXT}" -n external-secrets get secret conjur-creds \
  -o jsonpath='{.data.apikey}' > "${TMPDIR_SYNC}/apikey.b64"
oc --context "${HUB_CONTEXT}" -n banking-conjur get secret conjur-oss-conjur-ssl-ca-cert \
  -o jsonpath='{.data.tls\.crt}' > "${TMPDIR_SYNC}/ca.b64"

for ctx in ${SPOKE_CONTEXTS}; do
  echo "==> Syncing to spoke context ${ctx}"
  oc --context "${ctx}" create namespace external-secrets --dry-run=client -o yaml \
    | oc --context "${ctx}" apply -f -

  oc --context "${ctx}" -n external-secrets apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: conjur-creds
  namespace: external-secrets
type: Opaque
data:
  hostid: $(cat "${TMPDIR_SYNC}/hostid.b64")
  apikey: $(cat "${TMPDIR_SYNC}/apikey.b64")
EOF

  oc --context "${ctx}" -n external-secrets apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: conjur-ssl-ca
  namespace: external-secrets
type: Opaque
data:
  tls.crt: $(cat "${TMPDIR_SYNC}/ca.b64")
EOF
done

echo "Done. Ensure spoke ClusterSecretStore URL uses the acm Conjur Route host."
