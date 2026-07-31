#!/usr/bin/env bash
# Pre-populate Nexus proxy cache + Jenkins local .m2 by resolving both app POMs.
# Run once after bootstrap-nexus.sh (or whenever POMs gain heavy new deps).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACM_CONTEXT="${ACM_CONTEXT:-acm}"
CI_NS="${CI_NS:-banking-ci}"

echo "==> warming Maven deps via Jenkins PVC (in-cluster Nexus)"
oc --context "${ACM_CONTEXT}" -n "${CI_NS}" exec jenkins-0 -c jenkins -- bash -lc "
set -euo pipefail
cd /tmp
rm -rf warm-src
mkdir -p warm-src
"

# Copy poms + settings into the Jenkins pod and resolve.
oc --context "${ACM_CONTEXT}" -n "${CI_NS}" cp "${ROOT}/ci/maven/settings.xml" jenkins-0:/tmp/warm-src/settings.xml -c jenkins
for app in banking-service api-gateway; do
  oc --context "${ACM_CONTEXT}" -n "${CI_NS}" exec jenkins-0 -c jenkins -- mkdir -p "/tmp/warm-src/${app}"
  oc --context "${ACM_CONTEXT}" -n "${CI_NS}" cp "${ROOT}/apps/${app}/pom.xml" "jenkins-0:/tmp/warm-src/${app}/pom.xml" -c jenkins
done

oc --context "${ACM_CONTEXT}" -n "${CI_NS}" cp "${ROOT}/ci/scripts/ensure-maven-tools.sh" jenkins-0:/tmp/warm-src/ensure-maven-tools.sh -c jenkins
oc --context "${ACM_CONTEXT}" -n "${CI_NS}" exec jenkins-0 -c jenkins -- bash -lc '
set -euo pipefail
export JENKINS_HOME=/var/jenkins_home
export MAVEN_REPO_LOCAL="${JENKINS_HOME}/.m2/repository"
chmod +x /tmp/warm-src/ensure-maven-tools.sh
# shellcheck disable=SC1091
source /tmp/warm-src/ensure-maven-tools.sh
for app in banking-service api-gateway; do
  echo "==> dependency:go-offline ${app}"
  mvn -B -s /tmp/warm-src/settings.xml \
    -Dmaven.repo.local="${MAVEN_REPO_LOCAL}" \
    -DskipTests \
    -f "/tmp/warm-src/${app}/pom.xml" \
    dependency:go-offline || \
  mvn -B -s /tmp/warm-src/settings.xml \
    -Dmaven.repo.local="${MAVEN_REPO_LOCAL}" \
    -DskipTests \
    -f "/tmp/warm-src/${app}/pom.xml" \
    dependency:resolve
done
du -sh "${MAVEN_REPO_LOCAL}"
'

echo "Done. Subsequent Jenkins Maven package stages should hit the local cache + Nexus blobs."
