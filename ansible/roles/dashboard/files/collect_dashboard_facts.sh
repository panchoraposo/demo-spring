#!/usr/bin/env bash
# Collect live URLs and credentials for the banking demo dashboard.
# Env: ACM_CONTEXT, EAST_CONTEXT, WEST_CONTEXT, KIALI_NAMESPACE
set -euo pipefail

CTX="${ACM_CONTEXT:-acm}"
EAST="${EAST_CONTEXT:-east}"
WEST="${WEST_CONTEXT:-west}"
KIALI_NS="${KIALI_NAMESPACE:-istio-system}"
OC_TO=(--request-timeout=8s)

route_host() {
  local ctx="$1" ns="$2" name="$3"
  oc "${OC_TO[@]}" --context "${ctx}" -n "${ns}" get route "${name}" -o jsonpath='{.spec.host}' 2>/dev/null || true
}

first_route_host() {
  local ctx="$1" ns="$2" label="$3"
  oc "${OC_TO[@]}" --context "${ctx}" -n "${ns}" get route -l "${label}" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true
}

secret_val() {
  local ctx="$1" ns="$2" name="$3" key="$4"
  oc "${OC_TO[@]}" --context "${ctx}" -n "${ns}" get secret "${name}" -o "jsonpath={.data.${key}}" 2>/dev/null \
    | { base64 -d 2>/dev/null || true; }
}

# apps.<cluster-domain> from ManagedCluster console claim (works when spoke kubeconfig expired)
managed_apps_domain() {
  local cluster="$1"
  local console
  console="$(oc "${OC_TO[@]}" --context "${CTX}" get managedcluster "${cluster}" \
    -o jsonpath='{range .status.clusterClaims[?(@.name=="consoleurl.cluster.open-cluster-management.io")]}{.value}{end}' 2>/dev/null || true)"
  if [[ "${console}" =~ \.(apps\.[^/]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Route host via ACM ManagedClusterView when direct spoke context fails
mcv_route_host() {
  local cluster="$1" ns="$2" name="$3"
  local view="dash-collect-${name}"
  local host=""
  oc "${OC_TO[@]}" --context "${CTX}" -n "${cluster}" delete managedclusterview "${view}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if ! oc "${OC_TO[@]}" --context "${CTX}" -n "${cluster}" apply -f - >/dev/null 2>&1 <<EOF
apiVersion: view.open-cluster-management.io/v1beta1
kind: ManagedClusterView
metadata:
  name: ${view}
  namespace: ${cluster}
spec:
  scope:
    resource: routes
    name: ${name}
    namespace: ${ns}
EOF
  then
    return 0
  fi
  local i
  for i in 1 2 3 4 5 6; do
    host="$(oc "${OC_TO[@]}" --context "${CTX}" -n "${cluster}" get managedclusterview "${view}" \
      -o jsonpath='{.status.result.spec.host}' 2>/dev/null || true)"
    [[ -n "${host}" ]] && break
    sleep 1
  done
  oc "${OC_TO[@]}" --context "${CTX}" -n "${cluster}" delete managedclusterview "${view}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  printf '%s' "${host}"
}

# Prefer direct oc context; else short host from managed apps domain; else MCV
spoke_short_host() {
  local ctx="$1" cluster="$2" ns="$3" route="$4" prefix="$5"
  local host
  host="$(route_host "${ctx}" "${ns}" "${route}")"
  if [[ -z "${host}" ]]; then
    local apps
    apps="$(managed_apps_domain "${cluster}")"
    if [[ -n "${apps}" ]]; then
      host="${prefix}.${apps}"
    fi
  fi
  if [[ -z "${host}" ]]; then
    host="$(mcv_route_host "${cluster}" "${ns}" "${route}")"
  fi
  printf '%s' "${host}"
}

SSO="$(route_host "${CTX}" banking-idp sso)"
ARGOCD="$(route_host "${CTX}" openshift-gitops openshift-gitops-server)"
JENKINS="$(route_host "${CTX}" banking-ci jenkins)"
GITEA="$(route_host "${CTX}" banking-git gitea)"
CONJUR="$(route_host "${CTX}" banking-conjur conjur)"
NEXUS="$(route_host "${CTX}" nexus nexus)"
KIALI="$(route_host "${CTX}" "${KIALI_NS}" kiali)"
DEVSPACES="$(route_host "${CTX}" openshift-devspaces devspaces)"
TPA="$(oc "${OC_TO[@]}" --context "${CTX}" -n trusted-profile-analyzer get route -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.host}{"\n"}{end}' 2>/dev/null \
  | awk -F'\t' '$1 ~ /^server/ {print $2; exit}')"
REKOR="$(oc "${OC_TO[@]}" --context "${CTX}" -n trusted-artifact-signer get route -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.host}{"\n"}{end}' 2>/dev/null \
  | awk -F'\t' '$1 ~ /^rekor-search-ui/ {print $2; exit}')"
TUF="$(oc "${OC_TO[@]}" --context "${CTX}" -n trusted-artifact-signer get route -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.host}{"\n"}{end}' 2>/dev/null \
  | awk -F'\t' '$1 ~ /^tuf/ {print $2; exit}')"
QUAY="$(first_route_host "${CTX}" quay-enterprise 'quay-component=quay-app-route')"
if [[ -z "${QUAY}" ]]; then QUAY="$(route_host "${CTX}" quay-enterprise banking-quay-quay)"; fi

# Short demo hosts: gateway.<apps> (mesh) / si-gateway.<apps> (Service Interconnect)
EAST_GW="$(spoke_short_host "${EAST}" east banking-apps api-gateway gateway)"
WEST_GW="$(spoke_short_host "${WEST}" west banking-apps api-gateway gateway)"
EAST_SI_GW="$(spoke_short_host "${EAST}" east banking-si-apps api-gateway si-gateway)"
WEST_SI_GW="$(spoke_short_host "${WEST}" west banking-si-apps api-gateway si-gateway)"

# Network Observer console lives on west (SI path)
SI_OBSERVER="$(first_route_host "${WEST}" banking-si-apps 'app.kubernetes.io/name=network-observer')"
if [[ -z "${SI_OBSERVER}" ]]; then
  SI_OBSERVER="$(route_host "${WEST}" banking-si-apps banking-si-network-observer)"
fi
if [[ -z "${SI_OBSERVER}" ]]; then
  SI_OBSERVER="$(mcv_route_host west banking-si-apps banking-si-network-observer)"
fi

CONSOLE="$(oc "${OC_TO[@]}" --context "${CTX}" whoami --show-console 2>/dev/null || true)"

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
ARGOCD_PASS="$(oc "${OC_TO[@]}" --context "${CTX}" -n openshift-gitops extract secret/openshift-gitops-cluster --to=- --keys=admin.password 2>/dev/null || true)"
QUAY_ROBOT_USER="$(secret_val "${CTX}" banking-ci quay-ci username)"
QUAY_ROBOT_PASS="$(secret_val "${CTX}" banking-ci quay-ci password)"

CONJUR_KEY=""
POD="$(oc "${OC_TO[@]}" --context "${CTX}" -n banking-conjur get pod -l app=conjur-oss -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${POD}" ]]; then
  CONJUR_KEY="$(oc "${OC_TO[@]}" --context "${CTX}" -n banking-conjur exec "${POD}" -- \
    conjurctl role retrieve-key banking:user:admin 2>/dev/null | tr -d '\r\n' || true)"
fi

export SSO ARGOCD JENKINS GITEA CONJUR NEXUS KIALI DEVSPACES TPA REKOR TUF QUAY
export EAST_GW WEST_GW EAST_SI_GW WEST_SI_GW SI_OBSERVER CONSOLE APPS_DOMAIN
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
  "nexus_url": url(os.environ.get("NEXUS")),
  "kiali_url": url(os.environ.get("KIALI")),
  "devspaces_url": url(os.environ.get("DEVSPACES")),
  "tpa_url": url(os.environ.get("TPA")),
  "rekor_url": url(os.environ.get("REKOR")),
  "tuf_url": url(os.environ.get("TUF")),
  "quay_url": url(os.environ.get("QUAY")),
  "east_gateway_url": url(os.environ.get("EAST_GW")),
  "west_gateway_url": url(os.environ.get("WEST_GW")),
  "east_si_gateway_url": url(os.environ.get("EAST_SI_GW")),
  "west_si_gateway_url": url(os.environ.get("WEST_SI_GW")),
  "si_observer_url": url(os.environ.get("SI_OBSERVER")),
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
