# Maven deps resolve via Nexus on acm when settings.xml is in the build context.
FROM registry.access.redhat.com/ubi9/openjdk-21:1.21 AS build
USER root
WORKDIR /workspace
COPY --chown=185:0 pom.xml .
COPY --chown=185:0 src ./src
# Mirrors Maven Central + Red Hat GA via Nexus on acm (see ci/maven/settings.xml).
COPY --chown=185:0 settings.xml ./
USER 185
RUN mvn -B -s settings.xml -DskipTests package

FROM registry.access.redhat.com/ubi9/openjdk-21-runtime:1.21
COPY --from=build --chown=185:0 /workspace/target/api-gateway-*.jar /deployments/app.jar
EXPOSE 8080
USER 185
ENTRYPOINT ["java", "-jar", "/deployments/app.jar"]
