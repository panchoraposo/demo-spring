#!/usr/bin/env bash
# Application launcher ConsoleLinks on acm:
#   Gitea, Jenkins, Quay, Rekor Search UI, Kiali
# Discovers Route hosts so the demo stays portable across cluster domains.
# Each link uses the official community-project logo (HTTPS imageURL).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/console-link-icons.sh
source "${ROOT_DIR}/scripts/lib/console-link-icons.sh"

CTX="${KUBE_CONTEXT:-acm}"
SECTION="${CONSOLE_LINK_SECTION:-Banking Demo}"

apply_link() {
  local name="$1" text="$2" href="$3" image_url="$4"
  [[ -n "${href}" ]] || {
    echo "WARN: skip ConsoleLink ${name} (URL not found yet)" >&2
    return 0
  }
  oc --context "${CTX}" apply -f - <<YAML
apiVersion: console.openshift.io/v1
kind: ConsoleLink
metadata:
  name: ${name}
  labels:
    app.kubernetes.io/part-of: banking-demo
    cluster: acm
spec:
  href: "${href}"
  location: ApplicationMenu
  text: "${text}"
  applicationMenu:
    section: "${SECTION}"
    imageURL: "${image_url}"
YAML
  echo "ConsoleLink ${name} → ${href}"
}

jenkins_href() {
  local host
  host="$(oc --context "${CTX}" -n banking-ci get route jenkins \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "${host}" ]] && echo "https://${host}"
}

quay_href() {
  local host
  host="$(oc --context "${CTX}" -n quay-enterprise get route -l quay-component=quay \
    -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
  [[ -n "${host}" ]] && echo "https://${host}"
}

# Rekor Search UI only (not the Rekor API endpoint).
# Demo acm Route host (override with REKOR_SEARCH_UI_URL).
rekor_search_ui_href() {
  if [[ -n "${REKOR_SEARCH_UI_URL:-}" ]]; then
    echo "${REKOR_SEARCH_UI_URL%/}/"
    return 0
  fi
  local host
  host="$(oc --context "${CTX}" -n trusted-artifact-signer get route rekor-search-ui \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "${host}" ]]; then
    host="$(oc --context "${CTX}" -n trusted-artifact-signer get route \
      -l app.kubernetes.io/component=rekor-search-ui \
      -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
  fi
  if [[ -n "${host}" ]]; then
    echo "https://${host}/"
    return 0
  fi
  # Known acm demo Route (cluster-k7kqp).
  echo "https://rekor-search-ui-trusted-artifact-signer.apps.cluster-k7kqp.k7kqp.sandbox3321.opentlc.com/"
}

gitea_href() {
  local host
  host="$(oc --context "${CTX}" -n banking-git get route gitea \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "${host}" ]] && echo "https://${host}"
}

kiali_href() {
  local host
  host="$(oc --context "${CTX}" -n istio-system get route kiali \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "${host}" ]] && echo "https://${host}"
}

acs_href() {
  local host
  host="$(oc --context "${CTX}" -n stackrox get route central \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "${host}" ]] && echo "https://${host}"
}

nexus_href() {
  local host
  host="$(oc --context "${CTX}" -n nexus get route nexus \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "${host}" ]] && echo "https://${host}"
}

apply_link banking-demo-gitea "Gitea" "$(gitea_href)" "$(console_link_icon_gitea)"
apply_link banking-demo-jenkins "Jenkins" "$(jenkins_href)" "$(console_link_icon_jenkins)"
apply_link banking-demo-quay "Quay" "$(quay_href)" "$(console_link_icon_quay)"
apply_link banking-demo-nexus "Nexus" "$(nexus_href)" "$(console_link_icon_quay)"
apply_link banking-demo-acs "ACS Central" "$(acs_href)" "$(console_link_icon_rekor)"
apply_link banking-demo-rekor-search-ui "Rekor Search UI" "$(rekor_search_ui_href)" "$(console_link_icon_rekor)"
apply_link banking-demo-kiali "Kiali" "$(kiali_href)" "$(console_link_icon_kiali)"

# Drop the old Rekor API ConsoleLink name if it still exists from earlier installs.
oc --context "${CTX}" delete consolelink banking-demo-rekor --ignore-not-found >/dev/null 2>&1 || true

echo "Console links applied on ${CTX} (ApplicationMenu → ${SECTION})."
