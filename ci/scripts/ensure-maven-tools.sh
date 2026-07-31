#!/usr/bin/env bash
# Ensure Maven is available. Prefer the JDK already in jenkins/jenkins:lts-jdk21
# (/opt/java/openjdk). Maven is installed once under JENKINS_HOME/.tools (PVC).
set -euo pipefail

TOOLS_ROOT="${MAVEN_TOOLS_ROOT:-${JENKINS_HOME:-${HOME}}/.tools}"
MVN_DIR="${TOOLS_ROOT}/apache-maven-3.9.9"
mkdir -p "${TOOLS_ROOT}"

if [[ -z "${JAVA_HOME:-}" ]]; then
  for candidate in /opt/java/openjdk /usr/lib/jvm/java-21-openjdk /usr/lib/jvm/java-17-openjdk; do
    if [[ -x "${candidate}/bin/java" ]]; then
      export JAVA_HOME="${candidate}"
      break
    fi
  done
fi
[[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]] || {
  echo "ERROR: JAVA_HOME not found (expected Jenkins lts-jdk21 image)" >&2
  exit 1
}
export PATH="${JAVA_HOME}/bin:${PATH}"

if [[ ! -x "${MVN_DIR}/bin/mvn" ]]; then
  echo "==> installing Apache Maven 3.9.9 → ${MVN_DIR}"
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/maven.tgz" \
    "https://archive.apache.org/dist/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz"
  tar -xzf "${tmp}/maven.tgz" -C "${TOOLS_ROOT}"
  rm -rf "${tmp}"
fi

export PATH="${MVN_DIR}/bin:${PATH}"
echo "JAVA_HOME=${JAVA_HOME}"
java -version 2>&1 | head -1
mvn -version | head -1
