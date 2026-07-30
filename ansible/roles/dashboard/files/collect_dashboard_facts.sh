#!/usr/bin/env bash
# Collect live URLs and credentials for the banking demo dashboard.
# Env: ACM_CONTEXT, EAST_CONTEXT, WEST_CONTEXT, KIALI_NAMESPACE
set -euo pipefail

CTX="${ACM_CONTEXT:-acm}"
EAST="${EAST_CONTEXT:-east}"
WEST="${WEST_CONTEXT:-west}"
KIALI_NS="${KIALI_NAMESPACE:-istio-system}"

route_host() {
  local ctx="$1" ns="$2" name="$3"
  oc --context "${ctx}" -n "${ns}" get route "${name}" -o jsonpath='{.spec.host}' 2>/dev/null || true
}

first_route_host() {
  local ctx="$1" ns="$2" label="$3"
  oc --context "${ctx}" -n "${ns}" get route -l "${label}" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true
}

secret_val() {
  local ctx="$1" ns="$2" name="$3" key="$4"
  oc --context "${ctx}" -n "${ns}" get secret "${name}" -o "jsonpath={.data.${key}}" 2>/dev/null \
    | { base64 -d 2>/dev/null || true; }
}

SSO="$(route_host "${CTX}" banking-idp sso)"
ARGOCD="$(route_host "${CTX}" openshift-gitops openshift-gitops-server)"
JENKINS="$(route_host "${CTX}" banking-ci jenkins)"
GITEA="$(route_host "${CTX}" banking-git gitea)"
CONJUR="$(route_host "${CTX}" banking-conjur conjur)"
KIALI="$(route_host "${CTX}" "${KIALI_NS}" kiali)"
DEVSPACES="$(route_host "${CTX}" openshift-devspaces devspaces)"
TPA="$(oc --context "${CTX}" -n trusted-profile-analyzer get route -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.host}{"\n"}{end}' 2>/dev/null \
  | awk -F'\t' '$1 ~ /^server/ {print $2; exit}')"
REKOR="$(oc --context "${CTX}" -n trusted-artifact-signer get route -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.host}{"\n"}{end}' 2>/dev/null \
  | awk -F'\t' '$1 ~ /^rekor-search-ui/ {print $2; exit}')"
TUF="$(oc --context "${CTX}" -n trusted-artifact-signer get route -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.host}{"\n"}{end}' 2>/dev/null \
  | awk -F'\t' '$1 ~ /^tuf/ {print $2; exit}')"
QUAY="$(first_route_host "${CTX}" quay-enterprise 'quay-component=quay-app-route')"
if [[ -z "${QUAY}" ]]; then QUAY="$(route_host "${CTX}" quay-enterprise banking-quay-quay)"; fi
EAST_GW="$(route_host "${EAST}" banking-apps api-gateway)"
WEST_GW="$(route_host "${WEST}" banking-apps api-gateway)"
CONSOLE="$(oc --context "${CTX}" whoami --show-console 2>/dev/null || true)"

APPS_DOMAIN=""
if [[ -n "${SSO}" && "${SSO}" == sso.* ]]; then
  APPS_DOMAIN="${SSO#sso.}"
elif [[ -n "${ARGOCD}" ]]; then
  APPS_DOMAIN="${ARGOCD#openshift-gitops-server-openshift-gitops.}"
fi

KC_USER="$(secret_val "${CTX}" banking-idp keycloak-admin username)"
KC_PASS="$(secret_val "${CTX}" banking-idp keycloak-admin password)"
JENKINS_USER="$(secret_val "${CTX}" banking-ci jenkins-admin jenkins-admin-user)"
JENKINS_PASS="$(secret_val "${CTX}" banking-ci jenkins-admin jenkins-admin-password)"
ARGOCD_PASS="$(oc --context "${CTX}" -n openshift-gitops extract secret/openshift-gitops-cluster --to=- --keys=admin.password 2>/dev/null || true)"
QUAY_ROBOT_USER="$(secret_val "${CTX}" banking-ci quay-ci username)"
QUAY_ROBOT_PASS="$(secret_val "${CTX}" banking-ci quay-ci password)"

CONJUR_KEY=""
POD="$(oc --context "${CTX}" -n banking-conjur get pod -l app=conjur-oss -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${POD}" ]]; then
  CONJUR_KEY="$(oc --context "${CTX}" -n banking-conjur exec "${POD}" -- \
    conjurctl role retrieve-key banking:user:admin 2>/dev/null | tr -d '\r\n' || true)"
fi

export SSO ARGOCD JENKINS GITEA CONJUR KIALI DEVSPACES TPA REKOR TUF QUAY EAST_GW WEST_GW CONSOLE APPS_DOMAIN
export KC_USER KC_PASS JENKINS_USER JENKINS_PASS ARGOCD_PASS QUAY_ROBOT_USER QUAY_ROBOT_PASS CONJUR_KEY

python3 - <<'PY'
import json, os

def url(host):
    host = (host or "").strip()
    return f"https://{host}" if host else ""

print(json.dumps({
  "apps_domain": (os.environ.get("APPS_DOMAIN") or "").strip(),
  "console_url": (os.environ.get("CONSOLE") or "").strip(),
  "keycloak_url": url(os.environ.get("SSO")),
  "argocd_url": url(os.environ.get("ARGOCD")),
  "jenkins_url": url(os.environ.get("JENKINS")),
  "gitea_url": url(os.environ.get("GITEA")),
  "conjur_url": url(os.environ.get("CONJUR")),
  "kiali_url": url(os.environ.get("KIALI")),
  "devspaces_url": url(os.environ.get("DEVSPACES")),
  "tpa_url": url(os.environ.get("TPA")),
  "rekor_url": url(os.environ.get("REKOR")),
  "tuf_url": url(os.environ.get("TUF")),
  "quay_url": url(os.environ.get("QUAY")),
  "east_gateway_url": url(os.environ.get("EAST_GW")),
  "west_gateway_url": url(os.environ.get("WEST_GW")),
  "keycloak_admin_user": (os.environ.get("KC_USER") or "").strip(),
  "keycloak_admin_password": (os.environ.get("KC_PASS") or "").strip(),
  "jenkins_admin_user": (os.environ.get("JENKINS_USER") or "").strip(),
  "jenkins_admin_password": (os.environ.get("JENKINS_PASS") or "").strip(),
  "argocd_admin_password": (os.environ.get("ARGOCD_PASS") or "").strip(),
  "quay_robot_user": (os.environ.get("QUAY_ROBOT_USER") or "").strip(),
  "quay_robot_password": (os.environ.get("QUAY_ROBOT_PASS") or "").strip(),
  "conjur_admin_api_key": (os.environ.get("CONJUR_KEY") or "").strip(),
}))
PY
