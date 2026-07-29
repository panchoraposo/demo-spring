#!/usr/bin/env bash
# Install a shared root CA (+ per-cluster intermediates) into istio-system/cacerts
# on east and west. Required for ambient multi-network HBONE mTLS across clusters.
#
# Certs are stored locally under .mesh-certs/ (gitignored). Re-run is idempotent
# unless FORCE_REGEN=1.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CERTS_DIR="${CERTS_DIR:-${ROOT_DIR}/.mesh-certs}"
CONTEXTS="${CONTEXTS:-east west}"
FORCE_REGEN="${FORCE_REGEN:-0}"

mkdir -p "${CERTS_DIR}"
cd "${CERTS_DIR}"

if [[ ! -f root-cert.pem || "${FORCE_REGEN}" == "1" ]]; then
  echo "==> Generating shared root + intermediates in ${CERTS_DIR}"
  cat > extensions.cnf <<'EOF'
[ v3_ca ]
basicConstraints = critical,CA:TRUE
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF
  openssl req -new -newkey rsa:4096 -x509 -sha256 -days 3650 -nodes \
    -keyout root-key.pem -out root-cert.pem \
    -subj "/O=banking-mesh/CN=Root CA" \
    -extensions v3_ca -config extensions.cnf
  for ctx in ${CONTEXTS}; do
    openssl req -new -newkey rsa:4096 -nodes \
      -keyout "${ctx}-key.pem" -out "${ctx}.csr" \
      -subj "/O=banking-mesh/CN=${ctx}"
    openssl x509 -req -days 3650 -sha256 \
      -CA root-cert.pem -CAkey root-key.pem -set_serial "$((RANDOM))" \
      -in "${ctx}.csr" -out "${ctx}-cert.pem" \
      -extfile extensions.cnf -extensions v3_ca
    cat "${ctx}-cert.pem" root-cert.pem > "${ctx}-cert-chain.pem"
  done
fi

for ctx in ${CONTEXTS}; do
  echo "==> Installing cacerts on ${ctx}"
  oc --context "${ctx}" create namespace istio-system --dry-run=client -o yaml \
    | oc --context "${ctx}" apply -f -
  oc --context "${ctx}" -n istio-system delete secret cacerts --ignore-not-found
  oc --context "${ctx}" -n istio-system create secret generic cacerts \
    --from-file=root-cert.pem=root-cert.pem \
    --from-file=ca-cert.pem="${ctx}-cert.pem" \
    --from-file=ca-key.pem="${ctx}-key.pem" \
    --from-file=cert-chain.pem="${ctx}-cert-chain.pem"
  oc --context "${ctx}" -n istio-system delete pods -l app=istiod --wait=false || true
  oc --context "${ctx}" -n ztunnel delete pods --all --wait=false || true
done

echo "Done. Wait for istiod/ztunnel Ready, then re-check roots match:"
echo "  oc --context east -n istio-system get cm istio-ca-root-cert -o jsonpath='{.data.root-cert\\.pem}' | openssl x509 -noout -fingerprint"
echo "  oc --context west -n istio-system get cm istio-ca-root-cert -o jsonpath='{.data.root-cert\\.pem}' | openssl x509 -noout -fingerprint"
