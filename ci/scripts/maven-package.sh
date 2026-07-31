#!/usr/bin/env bash
# Package a Spring app with a persistent local Maven repo (fast subsequent builds).
#
# Env:
#   APP_DIR              path to app (e.g. apps/banking-service)
#   MAVEN_REPO_LOCAL     default: $JENKINS_HOME/.m2/repository (PVC-backed on Jenkins)
#   NEXUS settings       ci/maven/settings.xml (in-cluster Nexus)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/ci/scripts/ensure-maven-tools.sh"

APP_DIR="${APP_DIR:?set APP_DIR=apps/<name>}"
SETTINGS="${SETTINGS:-${ROOT}/ci/maven/settings.xml}"
MAVEN_REPO_LOCAL="${MAVEN_REPO_LOCAL:-${JENKINS_HOME:-${HOME}}/.m2/repository}"
mkdir -p "${MAVEN_REPO_LOCAL}"

# Fresh settings into the app dir (also used if a full Dockerfile build is needed).
cp -f "${SETTINGS}" "${APP_DIR}/settings.xml"

echo "==> mvn package ${APP_DIR} (localRepo=${MAVEN_REPO_LOCAL})"
# -C: concurrent downloads from Nexus; reuse warmed .m2 across builds.
mvn -B -s "${SETTINGS}" \
  -Dmaven.repo.local="${MAVEN_REPO_LOCAL}" \
  -Dorg.slf4j.simpleLogger.log.org.apache.maven.cli.transfer.Slf4jMavenTransferListener=warn \
  -T 1C \
  -DskipTests \
  -f "${APP_DIR}/pom.xml" \
  package

# Drop Spring Boot ".jar.original" so Dockerfile COPY target/*-*.jar is unambiguous.
rm -f "${APP_DIR}/target/"*.jar.original
jar="$(ls -1 "${APP_DIR}/target/"*.jar 2>/dev/null | grep -vE 'sources|javadoc' | head -1 || true)"
[[ -n "${jar}" ]] || { echo "ERROR: no jar in ${APP_DIR}/target" >&2; exit 1; }
echo "PACKAGED_JAR=${jar}"
ls -lh "${jar}"
