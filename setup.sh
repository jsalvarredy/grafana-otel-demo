#!/bin/bash

# Simple Grafana LGTM + OpenTelemetry Demo Setup Script
# This script creates a Kind cluster and deploys:
# - Nginx Ingress Controller
# - Grafana (UI)
# - Loki (Logs)
# - Tempo (Traces)
# - Loki (Logs)
# - Tempo (Traces)
# - Prometheus (Metrics)
# - OpenTelemetry Collector
# - Demo Node.js & Python apps instrumented with OpenTelemetry

set -e  # Exit on any error

echo "🚀 Starting Grafana LGTM + OpenTelemetry Demo Setup..."

# ============================================================================
# PREREQUISITES CHECK
# ============================================================================
echo "📋 Checking prerequisites..."
command -v kind >/dev/null 2>&1 || { echo "❌ kind is required"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl is required"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "❌ helm is required"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "❌ docker is required"; exit 1; }
command -v helmfile >/dev/null 2>&1 || { echo "❌ helmfile is required"; exit 1; }
echo "✅ All prerequisites found"

# ============================================================================
# KUBECONFIG SETUP
# ============================================================================
export KUBECONFIG="$PWD/kind/.kube/config"
mkdir -p kind/.kube

# ============================================================================
# KIND CLUSTER CREATION
# ============================================================================
if kind get clusters 2>/dev/null | grep -q "^grafana-otel-demo$"; then
  echo "⚠️  Kind cluster 'grafana-otel-demo' already exists. Reusing it."
else
  echo "📦 Creating Kind cluster 'grafana-otel-demo'..."
  # reusing the config that exposes ports
  kind create cluster --config kind/.kind/config.yaml --name grafana-otel-demo
  echo "✅ Kind cluster created"
fi

# ============================================================================
# DEPLOY INFRASTRUCTURE VIA HELMFILE
# ============================================================================
echo "🚀 Deploying Infrastructure with Helmfile..."

# Ensure monitoring namespace exists (sometimes handy if helmfile expects it or for hooks)
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Apply all helmfiles in kind/helmfile.d/
helmfile -f kind/helmfile.d/ apply

echo "✅ Grafana Observability Stack installed"


echo "🌐 Exposing Grafana via Ingress (configured in Helm values)..."
echo "📊 Importing Grafana Dashboards (K8s & Logs)..."
kubectl apply -f kind/dashboards/k8s-dashboard-cm.yaml
kubectl apply -f kind/dashboards/logs-search-cm.yaml

# ============================================================================
# BUILD AND DEPLOY DEMO APPLICATIONS
# ============================================================================
echo "🚀 Building and Deploying Demo Applications..."

# Build Images
docker build -t otel-demo-app:latest src/otel-app
docker build -t otel-python-app:latest src/otel-python-app

# Load Images
kind load docker-image otel-demo-app:latest --name grafana-otel-demo
kind load docker-image otel-python-app:latest --name grafana-otel-demo

# Deploy Apps
helm upgrade --install otel-demo-app charts/otel-demo-app \
  --namespace demo \
  --create-namespace \
  -f charts/otel-demo-app/values.yaml \
  --wait --timeout 3m

helm upgrade --install otel-python-app charts/otel-python-app \
  --namespace demo \
  -f charts/otel-python-app/values.yaml \
  --wait --timeout 3m

# ============================================================================
# GENERATE SAMPLE TRAFFIC
# ============================================================================
echo "🎲 Generating sample traffic to create observability data..."
echo "   This will create traces, logs, and metrics in Grafana"

# Generate diverse traffic to different endpoints
for i in {1..20}; do
  # Node.js app traffic
  curl -s -H "Host: otel-example.localhost" http://localhost/ > /dev/null || true
  curl -s -H "Host: otel-example.localhost" http://localhost/rolldice > /dev/null || true
  curl -s -H "Host: otel-example.localhost" http://localhost/work > /dev/null || true
  curl -s -H "Host: otel-example.localhost" http://localhost/health > /dev/null || true
  # Generate some errors for interesting data
  if (( i % 5 == 0 )); then
    curl -s -H "Host: otel-example.localhost" http://localhost/error > /dev/null || true
  fi
  
  # Python app traffic
  curl -s -H "Host: python-otel-example.localhost" http://localhost/ > /dev/null || true
  curl -s -H "Host: python-otel-example.localhost" http://localhost/rolldice > /dev/null || true
  curl -s -H "Host: python-otel-example.localhost" http://localhost/work > /dev/null || true
  curl -s -H "Host: python-otel-example.localhost" http://localhost/health > /dev/null || true
  if (( i % 5 == 0 )); then
    curl -s -H "Host: python-otel-example.localhost" http://localhost/error > /dev/null || true
  fi
  
  echo -n "."
  sleep 0.5
done

echo ""
echo "✅ Sample traffic generated"
# ============================================================================
# SETUP COMPLETE
# ============================================================================
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ Setup Complete! Grafana Observability + OTel Demo is ready"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "📊 Grafana UI:"
echo "   URL:      http://grafana-otel-demo.localhost"
echo "   User:     admin"
echo "   Password: Mikroways123"
echo ""
echo "🚀 Demo Applications:"
echo "   Node.js:  http://otel-example.localhost/"
echo "   Python:   http://python-otel-example.localhost/"
echo ""
echo "📝 Add to /etc/hosts: 127.0.0.1 grafana-otel-demo.localhost otel-example.localhost python-otel-example.localhost"
echo ""
echo "🔥 Generate traffic by visiting the app URLs!"


[ ! -f .envrc ] && cp .envrc-example .envrc && direnv allow
