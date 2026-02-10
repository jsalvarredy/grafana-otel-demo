# Shipping Service Dockerfile
# This service has NO OpenTelemetry instrumentation - Beyla eBPF handles all observability

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

# Copy the built JAR
COPY --from=build /app/target/*.jar app.jar

# Create non-root user
RUN addgroup -g 1000 appgroup && \
    adduser -u 1000 -G appgroup -D appuser
USER appuser

EXPOSE 8080

# Note: No OTEL Java agent is added here - Beyla will instrument via eBPF
ENTRYPOINT ["java", "-jar", "app.jar"]
