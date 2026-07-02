# Shipping Service Dockerfile (Java 17 / Spring Boot)
#
# Observability: this image bakes in the OpenTelemetry Java agent (bytecode
# auto-instrumentation, ZERO application code changes) so the service emits
# metrics, traces and logs on ANY kernel. The agent is enabled by the Helm
# chart via JAVA_TOOL_OPTIONS (instrumentation.javaAgent.enabled, the default).
#
# Beyla eBPF remains available as an opt-in alternative (charts/shipping-service
# values.yaml -> beyla.enabled) for kernels with BTF support. Keep exactly one
# of the two enabled to avoid double-counting HTTP metrics.

# Build stage
FROM maven:3.9-eclipse-temurin-17-alpine AS build
WORKDIR /app

# Copy pom.xml and download dependencies
COPY pom.xml .
RUN mvn dependency:go-offline -B

# Copy source code and build
COPY src ./src
RUN mvn package -DskipTests -B

# Runtime stage
FROM eclipse-temurin:17-jre-alpine

WORKDIR /app

# OpenTelemetry Java agent. Pinned for reproducibility and baked into the image
# so the demo works offline (no download at pod start). Activated only when
# instrumentation.javaAgent.enabled=true (default) in the Helm chart.
ARG OTEL_AGENT_VERSION=2.29.0
ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar /otel/opentelemetry-javaagent.jar

# Copy the built JAR
COPY --from=build /app/target/*.jar app.jar

# Create non-root user and make the agent jar world-readable for it.
RUN addgroup -g 1000 appgroup && \
    adduser -u 1000 -G appgroup -D appuser && \
    chmod 0644 /otel/opentelemetry-javaagent.jar
USER appuser

EXPOSE 8080

# JAVA_TOOL_OPTIONS (set by the chart) makes the JVM pick up the -javaagent
# without changing this entrypoint.
ENTRYPOINT ["java", "-jar", "app.jar"]
