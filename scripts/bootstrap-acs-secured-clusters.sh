#!/usr/bin/env bash
# Register east/west as RHACS secured clusters against Central on acm.
#
# Steps:
#   1) Ensure RHACS Operator is installed on east/west
#   2) Generate a Cluster Registration Secret (CRS) or init-bundle from Central
#   3) Apply secrets + SecuredCluster CR on each spoke
#
# Prerequisites: Central Deployed on acm (API reachable).
set -euo pipefail

ACM_CONTEXT="${ACM_CONTEXT:-acm}"
MANAGED_CONTEXTS="${MANAGED_CONTEXTS:-east west}"
STACKROX_NS="${STACKROX_NS:-stackrox}"
BUNDLE_NAME="${BUNDLE_NAME:-banking-managed-$(date +%Y%m%d)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_LOCAL}"' EXIT

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need oc; need curl; need jq

install_roxctl() {
  local ver out="${TMPDIR_LOCAL}/roxctl"
  if command -v roxctl >/dev/null 2>&1; then
    command -v roxctl
    return
  fi
  ver="$(curl -sk -u "admin:${ROX_ADMIN_PASSWORD}" "${CENTRAL}/v1/metadata" | jq -r '.version // empty')"
  [[ -n "${ver}" ]] || ver="4.11.2"
  local os="Linux"
  case "$(uname -s)" in
    Darwin) os="Darwin" ;;
    *) os="Linux" ;;
  esac
  echo "==> downloading roxctl ${ver} (${os})" >&2
  curl -fsSL -o "${out}" "https://mirror.openshift.com/pub/rhacs/assets/${ver}/bin/${os}/roxctl"
  chmod +x "${out}"
  echo "${out}"
}

echo "==> resolving Central"
HOST="$(oc --context "${ACM_CONTEXT}" -n "${STACKROX_NS}" get route central -o jsonpath='{.spec.host}')"
CENTRAL="https://${HOST}"
CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT:-${HOST}:443}"
echo "Central: ${CENTRAL}"
echo "Endpoint for sensors: ${CENTRAL_ENDPOINT}"

if [[ -z "${ROX_ADMIN_PASSWORD:-}" ]]; then
  ROX_ADMIN_PASSWORD="$(oc --context "${ACM_CONTEXT}" -n "${STACKROX_NS}" get secret central-htpasswd \
    -o jsonpath='{.data.password}' | base64 -d)"
fi

ROXCTL="$(install_roxctl)"
export ROX_ADMIN_PASSWORD
# roxctl uses ROX_ENDPOINT (not ROX_CENTRAL_ADDRESS) for CLI → Central.
export ROX_ENDPOINT="${CENTRAL_ENDPOINT}"

SECRETS_FILE="${TMPDIR_LOCAL}/acs-cluster-secrets.yaml"
echo "==> generating registration secrets (${BUNDLE_NAME})"
# Prefer CRS (RHACS 4.11+); fall back to init-bundles.
if "${ROXCTL}" central crs generate "${BUNDLE_NAME}" \
      --output "${SECRETS_FILE}" \
      -e "${CENTRAL_ENDPOINT}" \
      --insecure-skip-tls-verify -p "${ROX_ADMIN_PASSWORD}" 2>"${TMPDIR_LOCAL}/crs.err"; then
  echo "  used Cluster Registration Secret (CRS)"
elif "${ROXCTL}" central init-bundles generate "${BUNDLE_NAME}" \
      --output-secrets "${SECRETS_FILE}" \
      -e "${CENTRAL_ENDPOINT}" \
      --insecure-skip-tls-verify -p "${ROX_ADMIN_PASSWORD}" 2>"${TMPDIR_LOCAL}/ib.err"; then
  echo "  used init-bundle (CRS unavailable)"
else
  echo "ERROR: could not generate CRS or init-bundle" >&2
  cat "${TMPDIR_LOCAL}/crs.err" "${TMPDIR_LOCAL}/ib.err" >&2 || true
  exit 1
fi

# Ensure spoke operators + apply secrets + SecuredCluster
for ctx in ${MANAGED_CONTEXTS}; do
  echo
  echo "==> ${ctx}: RHACS Operator"
  oc --context "${ctx}" apply -f "${ROOT}/gitops/platform/operators-spoke/namespace-rhacs.yaml"
  echo "    waiting for CSV…"
  for i in $(seq 1 36); do
    phase="$(oc --context "${ctx}" -n rhacs-operator get csv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
      | awk '/rhacs-operator/{print $2; exit}')"
    echo "    [$i] CSV=${phase:-pending}"
    [[ "${phase}" == "Succeeded" ]] && break
    sleep 10
  done

  echo "==> ${ctx}: apply registration secrets"
  oc --context "${ctx}" create namespace "${STACKROX_NS}" --dry-run=client -o yaml \
    | oc --context "${ctx}" apply -f - >/dev/null
  oc --context "${ctx}" -n "${STACKROX_NS}" apply -f "${SECRETS_FILE}"

  echo "==> ${ctx}: SecuredCluster → ${CENTRAL_ENDPOINT}"
  # Patch overlay endpoint then apply
  overlay="${ROOT}/gitops/components/rhacs-secured/overlays/${ctx}"
  sed -i.bak -E "s|value: .*apps\\..*:443|value: ${CENTRAL_ENDPOINT}|; s|value: CENTRAL_ENDPOINT|value: ${CENTRAL_ENDPOINT}|" \
    "${overlay}/kustomization.yaml" 2>/dev/null || true
  rm -f "${overlay}/kustomization.yaml.bak"
  # Ensure clusterName + endpoint via live apply
  oc --context "${ctx}" apply -k "${overlay}"
  # Force endpoint in case kustomize still had placeholder
  oc --context "${ctx}" -n "${STACKROX_NS}" patch securedclusters.platform.stackrox.io stackrox-secured-cluster-services \
    --type merge -p "{\"spec\":{\"clusterName\":\"${ctx}\",\"centralEndpoint\":\"${CENTRAL_ENDPOINT}\"}}" \
    2>/dev/null || true

  echo "==> ${ctx}: Argo Application"
  oc --context "${ctx}" -n openshift-gitops apply -f "${ROOT}/gitops/applications/${ctx}/rhacs-secured.yaml" || true
done

echo
echo "==> waiting for SecuredCluster Available on spokes"
for ctx in ${MANAGED_CONTEXTS}; do
  for i in $(seq 1 36); do
    avail="$(oc --context "${ctx}" -n "${STACKROX_NS}" get securedclusters.platform.stackrox.io stackrox-secured-cluster-services \
      -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "?")"
    echo "  ${ctx}: Available=${avail}"
    [[ "${avail}" == "True" ]] && break
    sleep 10
  done
done

echo
echo "==> clusters known to Central"
"${ROXCTL}" central whoami -e "${CENTRAL_ENDPOINT}" --insecure-skip-tls-verify -p "${ROX_ADMIN_PASSWORD}" >/dev/null || true
curl -sk -u "admin:${ROX_ADMIN_PASSWORD}" "${CENTRAL}/v1/clusters" \
  | jq -r '.clusters[]? | "\(.name)\thealth=\(.healthStatus.overallHealthStatus // .status // "?")"' 2>/dev/null \
  || echo "(list clusters via ACS UI → Platform Configuration → Clusters)"

echo
echo "Done. Sensors on east/west talk to Central at ${CENTRAL_ENDPOINT}."
