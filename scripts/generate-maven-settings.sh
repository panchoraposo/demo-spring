#!/usr/bin/env bash
# Print a Maven settings.xml that mirrors all traffic to the acm Nexus Route.
# Usage:
#   ./scripts/generate-maven-settings.sh > ~/.m2/settings.xml
#   mvn -s <(./scripts/generate-maven-settings.sh) -f apps/banking-service/pom.xml package
set -euo pipefail

ACM_CONTEXT="${ACM_CONTEXT:-acm}"
NEXUS_NS="${NEXUS_NS:-nexus}"

if [[ -n "${NEXUS_MAVEN_URL:-}" ]]; then
  URL="${NEXUS_MAVEN_URL}"
else
  host="$(oc --context "${ACM_CONTEXT}" -n "${NEXUS_NS}" get route nexus -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "${host}" ]] || {
    echo "ERROR: cannot resolve Nexus Route (set NEXUS_MAVEN_URL or oc context ${ACM_CONTEXT})" >&2
    exit 1
  }
  URL="https://${host}/repository/maven-public/"
fi

cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.2.0 https://maven.apache.org/xsd/settings-1.2.0.xsd">
  <mirrors>
    <mirror>
      <id>nexus-maven-public</id>
      <name>Nexus maven-public (central + Red Hat GA)</name>
      <url>${URL}</url>
      <mirrorOf>*</mirrorOf>
    </mirror>
  </mirrors>
  <profiles>
    <profile>
      <id>nexus</id>
      <repositories>
        <repository>
          <id>nexus-maven-public</id>
          <url>${URL}</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </repository>
      </repositories>
      <pluginRepositories>
        <pluginRepository>
          <id>nexus-maven-public</id>
          <url>${URL}</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </pluginRepository>
      </pluginRepositories>
    </profile>
  </profiles>
  <activeProfiles>
    <activeProfile>nexus</activeProfile>
  </activeProfiles>
</settings>
EOF
