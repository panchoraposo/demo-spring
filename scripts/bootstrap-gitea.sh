#!/usr/bin/env bash
# Gitea on acm: install chart, seed banking/demo-spring (Spring apps + GitOps),
# create CI PAT and store it in Conjur (banking/github-ci/*).
#
# Usage:
#   scripts/bootstrap-gitea.sh           # install + seed (standalone)
#   scripts/bootstrap-gitea.sh install   # helm only (used by bootstrap-acm)
#   scripts/bootstrap-gitea.sh seed      # Job + optional git push (after Conjur)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTX="${KUBE_CONTEXT:-acm}"
NS="${GITEA_NS:-banking-git}"
CHART_REPO="${GITEA_CHART_REPO:-https://dl.gitea.com/charts/}"
CHART_VERSION="${GITEA_CHART_VERSION:-12.7.0}"
SOURCE_REPO="${SOURCE_REPO:-https://github.com/panchoraposo/demo-spring.git}"
GITEA_INTERNAL_URL="http://gitea-http.${NS}.svc:3000"
CLONE_URL="${GITEA_INTERNAL_URL}/banking/demo-spring.git"
MODE="${1:-all}"

gitea_install() {
  echo "==> context=${CTX} namespace=${NS} (install)"
  if ! command -v helm >/dev/null 2>&1; then
    echo "ERROR: helm is required to install Gitea" >&2
    exit 1
  fi

  echo "==> Applying namespace + OpenShift Route"
  oc --context "${CTX}" apply -k "${ROOT_DIR}/gitops/components/gitea"

  APPS_DOMAIN="$(oc --context "${CTX}" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  ROUTE_HOST="$(oc --context "${CTX}" -n "${NS}" get route gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  DESIRED_HOST=""
  [[ -n "${APPS_DOMAIN}" ]] && DESIRED_HOST="gitea.${APPS_DOMAIN}"
  # Prefer short demo host gitea.<domain> (migrate legacy gitea-<ns>.<domain>).
  if [[ -n "${DESIRED_HOST}" && "${ROUTE_HOST}" != "${DESIRED_HOST}" ]]; then
    ROUTE_HOST="${DESIRED_HOST}"
    echo "==> Patching Route host to ${ROUTE_HOST}"
    oc --context "${CTX}" -n "${NS}" patch route gitea --type merge \
      -p "{\"spec\":{\"host\":\"${ROUTE_HOST}\"}}" >/dev/null
  fi
  if [[ -z "${ROUTE_HOST}" ]]; then
    # Wait for the router to assign a host
    for i in $(seq 1 30); do
      ROUTE_HOST="$(oc --context "${CTX}" -n "${NS}" get route gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
      [[ -n "${ROUTE_HOST}" ]] && break
      sleep 2
    done
  fi
  [[ -n "${ROUTE_HOST}" ]] || { echo "ERROR: Route/gitea has no host" >&2; exit 1; }
  ROOT_URL="https://${ROUTE_HOST}/"
  echo "==> Gitea public URL: ${ROOT_URL}"

  helm repo add gitea-charts "${CHART_REPO}" >/dev/null 2>&1 || true
  helm repo update gitea-charts >/dev/null
  helm upgrade --install gitea gitea-charts/gitea \
    --kube-context "${CTX}" \
    --namespace "${NS}" \
    --version "${CHART_VERSION}" \
    --values "${ROOT_DIR}/gitops/components/gitea/helm-values.yaml" \
    --set gitea.config.server.DOMAIN="${ROUTE_HOST}" \
    --set gitea.config.server.SSH_DOMAIN="${ROUTE_HOST}" \
    --set gitea.config.server.ROOT_URL="${ROOT_URL}" \
    --set gitea.config.server.PROTOCOL=https \
    --wait --timeout 15m

  echo "==> Waiting for Gitea API on Route"
  for i in $(seq 1 60); do
    if curl -skf "https://${ROUTE_HOST}/api/v1/version" >/dev/null 2>&1; then
      echo "Gitea API ready via https://${ROUTE_HOST}"
      break
    fi
    if oc --context "${CTX}" -n "${NS}" get deploy gitea >/dev/null 2>&1; then
      oc --context "${CTX}" -n "${NS}" rollout status deploy/gitea --timeout=15s >/dev/null 2>&1 || true
    fi
    sleep 5
    if [[ "${i}" -eq 60 ]]; then
      echo "WARN: timed out waiting for Gitea API; continuing" >&2
    fi
  done

  echo "==> ConsoleLink ApplicationMenu → Gitea"
  # shellcheck source=lib/console-link-icons.sh
  source "${ROOT_DIR}/scripts/lib/console-link-icons.sh"
  GITEA_ICON="$(console_link_icon_gitea)"
  oc --context "${CTX}" apply -f - <<YAML
apiVersion: console.openshift.io/v1
kind: ConsoleLink
metadata:
  name: banking-demo-gitea
  labels:
    app.kubernetes.io/part-of: banking-demo
    cluster: acm
spec:
  href: "https://${ROUTE_HOST}"
  location: ApplicationMenu
  text: Gitea
  applicationMenu:
    section: Banking Demo
    imageURL: "${GITEA_ICON}"
YAML
}

gitea_seed() {
  echo "==> context=${CTX} namespace=${NS} (seed + PAT → Conjur)"
  oc --context "${CTX}" apply -k "${ROOT_DIR}/gitops/components/gitea-config"
  oc --context "${CTX}" -n "${NS}" delete job gitea-bootstrap --ignore-not-found --wait=true
  # Refresh Job manifest (SOURCE_REPO etc.)
  oc --context "${CTX}" apply -f "${ROOT_DIR}/gitops/components/gitea-config/job-bootstrap.yaml"
  echo "==> Waiting for Job/gitea-bootstrap"
  oc --context "${CTX}" -n "${NS}" wait --for=condition=complete "job/gitea-bootstrap" --timeout=20m

  ROUTE_HOST="$(oc --context "${CTX}" -n "${NS}" get route gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${ROUTE_HOST}" && -d "${ROOT_DIR}/.git" ]]; then
    # Spoke Argo cannot use the acm ClusterIP — rewrite placeholder to the real Route host
    # in a temporary copy before push (does not dirty the local working tree).
    APPS_DOMAIN="$(printf '%s' "${ROUTE_HOST}" | sed -E 's/^gitea-banking-git\.//; s/^gitea\.//')"
    echo "==> Rewriting REPLACE_ME_ACM_APPS_DOMAIN → ${APPS_DOMAIN} for spoke GitOps URLs"
    TMP_TREE="$(mktemp -d)"
    # Prefer working tree so uncommitted demo changes (Gitea manifests) are seeded.
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete --exclude .git --exclude .tools "${ROOT_DIR}/" "${TMP_TREE}/"
    else
      git -C "${ROOT_DIR}" archive --format=tar HEAD | tar -C "${TMP_TREE}" -xf -
    fi
    find "${TMP_TREE}/gitops" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 \
      | xargs -0 sed -i.bak "s|REPLACE_ME_ACM_APPS_DOMAIN|${APPS_DOMAIN}|g" 2>/dev/null || true
    find "${TMP_TREE}" -name '*.bak' -delete

    # shellcheck source=lib/conjur.sh
    source "${ROOT_DIR}/scripts/lib/conjur.sh"
    if conjur_init 2>/dev/null; then
      TOKEN="$(conjur_get_var banking/github-ci/token 2>/dev/null || true)"
      USERNAME="$(conjur_get_var banking/github-ci/username 2>/dev/null || echo git)"
      if [[ -n "${TOKEN}" && "${TOKEN}" != "replace-me" ]]; then
        echo "==> Pushing seeded tree (Spring apps + GitOps) to Gitea"
        PUSH_URL="https://${USERNAME}:${TOKEN}@${ROUTE_HOST}/banking/demo-spring.git"
        git -C "${TMP_TREE}" init -q
        git -C "${TMP_TREE}" checkout -B main
        git -C "${TMP_TREE}" config user.email "bootstrap@banking-demo.local"
        git -C "${TMP_TREE}" config user.name "Gitea Bootstrap"
        git -C "${TMP_TREE}" add -A
        git -C "${TMP_TREE}" commit -qm "bootstrap: seed demo-spring on Gitea"
        git -C "${TMP_TREE}" push "${PUSH_URL}" HEAD:main --force \
          || echo "WARN: git push failed (migrate from ${SOURCE_REPO} may already have content)" >&2
      fi
    fi
    rm -rf "${TMP_TREE}"
  fi

  echo
  echo "Gitea seed complete."
  echo "  In-cluster clone URL: ${CLONE_URL}"
  echo "  UI: https://$(oc --context "${CTX}" -n "${NS}" get route gitea -o jsonpath='{.spec.host}')"
  echo "  Conjur: banking/github-ci/{username,token}"
}

case "${MODE}" in
  install) gitea_install ;;
  seed) gitea_seed ;;
  all)
    gitea_install
    gitea_seed
    ;;
  *)
    echo "Usage: $0 [all|install|seed]" >&2
    exit 1
    ;;
esac
