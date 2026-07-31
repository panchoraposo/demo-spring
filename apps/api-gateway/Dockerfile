# CI image: jar is built on Jenkins with a persistent ~/.m2 cache (see ci/scripts/maven-package.sh).
FROM registry.access.redhat.com/ubi9/openjdk-21-runtime:1.21
COPY --chown=185:0 target/api-gateway-*.jar /deployments/app.jar
EXPOSE 8080
USER 185
ENTRYPOINT ["java", "-jar", "/deployments/app.jar"]
