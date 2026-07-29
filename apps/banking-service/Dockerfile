# Builder: Red Hat UBI 9 OpenJDK 21 (includes Maven tooling)
FROM registry.access.redhat.com/ubi9/openjdk-21:1.21 AS build
USER root
WORKDIR /workspace
COPY --chown=185:0 pom.xml .
COPY --chown=185:0 src ./src
USER 185
RUN mvn -B -DskipTests package

FROM registry.access.redhat.com/ubi9/openjdk-21-runtime:1.21
COPY --from=build --chown=185:0 /workspace/target/banking-service-*.jar /deployments/app.jar
EXPOSE 8080
USER 185
ENTRYPOINT ["java", "-jar", "/deployments/app.jar"]
