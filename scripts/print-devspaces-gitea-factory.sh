#!/usr/bin/env bash
# Print the Dev Spaces factory URL that opens banking/demo-spring from Gitea.
set -euo pipefail

ACM_CONTEXT="${ACM_CONTEXT:-acm}"
GITEA_NS="${GITEA_NS:-banking-git}"
DS_NS="${DS_NS:-openshift-devspaces}"

GITEA_HOST="$(oc --context "${ACM_CONTEXT}" -n "${GITEA_NS}" get route gitea -o jsonpath='{.spec.host}')"
DS_URL="$(oc --context "${ACM_CONTEXT}" -n "${DS_NS}" get checluster devspaces -o jsonpath='{.status.cheURL}' 2>/dev/null \
  || echo "https://devspaces.$(oc --context "${ACM_CONTEXT}" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')")"
REPO_URL="https://${GITEA_HOST}/banking/demo-spring.git"
FACTORY="${DS_URL}/#${REPO_URL}"

cat <<EOF
Dev Spaces ← Gitea (CVE demo)

  Gitea UI:     https://${GITEA_HOST}/banking/demo-spring
  Clone URL:    ${REPO_URL}
  Factory URL:  ${FACTORY}

Open the factory URL (OpenShift login → Dev Spaces). When prompted for Git
credentials to push, use Gitea user \`git\` / password \`BankingGitCiChangeMe!\`
(or a PAT from Gitea Settings → Applications).

Demo flow:
  1) Open factory URL → workspace loads apps/banking-service (Critical Tomcat CVE).
  2) In pom.xml add: <tomcat.version>10.1.35</tomcat.version>
  3) git commit && git push origin main
  4) Jenkins banking-service-ci starts (Gitea webhook or SCM poll ≤1 min).
EOF
