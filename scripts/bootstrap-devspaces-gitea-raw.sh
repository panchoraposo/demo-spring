#!/usr/bin/env bash
# Fix Dev Spaces factory opens against Gitea on OpenShift.
#
# Dev Spaces rewrites Gitea file fetches to:
#   https://raw.<gitea-host>/...
# The cluster wildcard cert is only *.apps.<domain>, so raw.<gitea-host>
# fails TLS hostname verification (and has no Route by default).
#
# This script:
#   1) Creates Route gitea-raw for raw.<gitea-host> with a matching SAN cert
#   2) Trusts that cert in OpenShift Dev Spaces (Che CA bundle + gitTrustedCerts)
set -euo pipefail

ACM_CONTEXT="${ACM_CONTEXT:-acm}"
GITEA_NS="${GITEA_NS:-banking-git}"
DS_NS="${DS_NS:-openshift-devspaces}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need oc; need openssl

GITEA_HOST="$(oc --context "${ACM_CONTEXT}" -n "${GITEA_NS}" get route gitea -o jsonpath='{.spec.host}')"
[[ -n "${GITEA_HOST}" ]] || { echo "ERROR: Route/gitea not found" >&2; exit 1; }
RAW_HOST="raw.${GITEA_HOST}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

if oc --context "${ACM_CONTEXT}" -n "${GITEA_NS}" get secret gitea-raw-tls >/dev/null 2>&1; then
  echo "==> reusing secret/${GITEA_NS}/gitea-raw-tls"
  oc --context "${ACM_CONTEXT}" -n "${GITEA_NS}" get secret gitea-raw-tls \
    -o jsonpath='{.data.tls\.crt}' | base64 -d >"${TMP}/tls.crt"
  oc --context "${ACM_CONTEXT}" -n "${GITEA_NS}" get secret gitea-raw-tls \
    -o jsonpath='{.data.tls\.key}' | base64 -d >"${TMP}/tls.key"
else
  echo "==> generating TLS cert for ${RAW_HOST}"
  # CN must be ≤64 chars; put the long hostname only in SAN.
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "${TMP}/tls.key" -out "${TMP}/tls.crt" \
    -subj "/CN=gitea-raw" \
    -addext "subjectAltName=DNS:${RAW_HOST},DNS:${GITEA_HOST}"
  oc --context "${ACM_CONTEXT}" -n "${GITEA_NS}" create secret tls gitea-raw-tls \
    --cert="${TMP}/tls.crt" --key="${TMP}/tls.key"
fi

CERT="$(cat "${TMP}/tls.crt")"
KEY="$(cat "${TMP}/tls.key")"

echo "==> applying Route/gitea-raw → ${RAW_HOST}"
oc --context "${ACM_CONTEXT}" -n "${GITEA_NS}" apply -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: gitea-raw
  namespace: ${GITEA_NS}
  labels:
    app.kubernetes.io/part-of: banking-demo
    app.kubernetes.io/name: gitea
    cluster: acm
spec:
  host: ${RAW_HOST}
  to:
    kind: Service
    name: gitea-http
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
    certificate: |
$(printf '%s\n' "${CERT}" | sed 's/^/      /')
    key: |
$(printf '%s\n' "${KEY}" | sed 's/^/      /')
  wildcardPolicy: None
EOF

echo "==> trusting cert in ${DS_NS}"
oc --context "${ACM_CONTEXT}" -n "${DS_NS}" create configmap gitea-raw-ca \
  --from-file=gitea-raw.crt="${TMP}/tls.crt" \
  --dry-run=client -o yaml | oc --context "${ACM_CONTEXT}" apply -f -
oc --context "${ACM_CONTEXT}" -n "${DS_NS}" label configmap gitea-raw-ca \
  app.kubernetes.io/part-of=che.eclipse.org \
  app.kubernetes.io/component=ca-bundle \
  --overwrite

oc --context "${ACM_CONTEXT}" -n "${DS_NS}" patch checluster devspaces --type merge -p '{
  "spec": {
    "devEnvironments": {
      "trustedCerts": {
        "gitTrustedCertsConfigMapName": "gitea-raw-ca"
      }
    }
  }
}'

echo "==> checking raw.devfile fetch"
code="$(curl -sk -o /dev/null -w '%{http_code}' \
  "https://${RAW_HOST}/banking/demo-spring/raw/branch/main/devfile.yaml")"
echo "  https://${RAW_HOST}/.../devfile.yaml → HTTP ${code}"
[[ "${code}" == "200" ]] || echo "WARNING: expected HTTP 200 from raw route" >&2

DS_URL="$(oc --context "${ACM_CONTEXT}" -n "${DS_NS}" get checluster devspaces \
  -o jsonpath='{.status.cheURL}' 2>/dev/null || true)"
DS_URL="${DS_URL:-https://devspaces.$(oc --context "${ACM_CONTEXT}" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')}"

cat <<EOF

Done. Wait ~30s for the Dev Spaces server to roll out the CA bundle, then open:

  ${DS_URL}/#https://${GITEA_HOST}/banking/demo-spring.git

If factory still fails, use the raw-devfile factory (avoids the raw. host):

  ${DS_URL}/#https://${GITEA_HOST}/banking/demo-spring/raw/branch/main/devfile.yaml

EOF
