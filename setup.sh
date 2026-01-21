#!/bin/bash

# Grafana OpenTelemetry Demo - Enhanced Setup Script
# This script creates a Kind cluster and deploys a complete observability stack:
# - Nginx Ingress Controller
# - Grafana LGTP Stack (Loki, Grafana, Tempo, Prometheus)
# - OpenTelemetry Collector
# - Demo microservices (Products Service &Orders Service)

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Helper functions
print_header() {
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
}

print_step() {
    echo -e "${BLUE}▶${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC}  $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${MAGENTA}ℹ${NC}  $1"
}

# Start
clear
print_header "Grafana LGTP + OpenTelemetry Demo Setup"
echo ""
print_info "Setup will take approximately 5-10 minutes depending on your internet connection."
echo ""

# ============================================================================
# PREREQUISITES CHECK
# ============================================================================
print_step "Checking prerequisites..."

check_command() {
    if command -v $1 &> /dev/null; then
        print_success "$1 found"
        return 0
    else
        print_error "$1 not found"
        return 1
    fi
}

all_ok=true
check_command kind || all_ok=false
check_command kubectl || all_ok=false
check_command helm || all_ok=false
check_command docker || all_ok=false
check_command helmfile || all_ok=false

if [ "$all_ok" = false ]; then
    echo ""
    print_error "Missing required tools. Please install them and try again."
    exit 1
fi

# Check if Docker is running
if ! docker info &> /dev/null; then
    print_error "Docker is not running. Please start Docker and try again."
    exit 1
fi

print_success "All prerequisites satisfied"
echo ""

# ============================================================================
# KUBECONFIG SETUP
# ============================================================================
export KUBECONFIG="$PWD/kind/.kube/config"
mkdir -p kind/.kube

# ============================================================================
# KIND CLUSTER CREATION
# ============================================================================
print_step "Setting up Kind cluster 'grafana-otel-demo'..."

if kind get clusters 2>/dev/null | grep -q "^grafana-otel-demo$"; then
  print_warning "Kind cluster already exists. Reusing it."
else
  print_step "Creating new Kind cluster..."
  kind create cluster --config kind/.kind/config.yaml --name grafana-otel-demo
  print_success "Kind cluster created"
fi
echo ""

# ============================================================================
# DEPLOY INFRASTRUCTURE VIA HELMFILE
# ============================================================================
print_header "Deploying Observability Stack"
echo ""

print_step "Creating monitoring namespace..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

print_step "Deploying infrastructure with Helmfile..."
print_info "This may take 3-5 minutes. Please be patient..."
echo ""


# Check if the "diff" plugin is NOT in the list
if ! helm plugin list | grep -q "diff"; then
    echo "helm-diff plugin not found. Installing..."
    helm plugin install https://github.com/databus23/helm-diff
else
    echo "helm-diff plugin is already installed. Skipping installation."
fi

helmfile -f kind/helmfile.d/ apply

echo ""
print_success "Grafana Observability Stack deployed"
echo ""

# ============================================================================
# DASHBOARD PROVISIONING
# ============================================================================
print_header "Provisioning Grafana Dashboards"
echo ""

print_step "Applying dashboard ConfigMaps..."
kubectl apply -f kind/dashboards/k8s-dashboard-cm.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/logs-search-cm.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/service-overview-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/tracing-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/logs-analysis-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/executive-dashboard.yaml > /dev/null 2>&1

print_success "6 dashboards provisioned (K8s, Logs Search, Service Overview, Tracing, Logs Analysis, Executive)"
echo ""

# ============================================================================
# BUILD AND DEPLOY DEMO APPLICATIONS
# ============================================================================
print_header "Building and Deploying Demo Applications"
echo ""

print_step "Building Products Service (Node.js)..."
docker build -t products-service:latest src/otel-app > /dev/null 2>&1
print_success "Products Service image built"

print_step "Building Orders Service (Python)..."
docker build -t orders-service:latest src/otel-python-app > /dev/null 2>&1
print_success "Orders Service image built"

print_step "Loading images into Kind cluster..."
kind load docker-image products-service:latest --name grafana-otel-demo > /dev/null 2>&1
kind load docker-image orders-service:latest --name grafana-otel-demo > /dev/null 2>&1
print_success "Images loaded into cluster"

print_step "Creating demo namespace..."
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

print_step "Deploying Products Service..."
helm upgrade --install otel-demo-app charts/otel-demo-app \
  --set image.repository=products-service \
  --set image.tag=latest \
  --namespace demo \
  --create-namespace \
  -f charts/otel-demo-app/values.yaml \
  --wait --timeout 3m > /dev/null 2>&1
print_success "Products Service deployed"

print_step "Deploying Orders Service..."
helm upgrade --install otel-python-app charts/otel-python-app \
  --set image.repository=orders-service \
  --set image.tag=latest \
  --namespace demo \
  -f charts/otel-python-app/values.yaml \
  --wait --timeout 3m > /dev/null 2>&1
print_success "Orders Service deployed"

echo ""
print_success "All services deployed successfully"
echo ""

# ============================================================================
# WAIT FOR SERVICES TO BE READY
# ============================================================================
print_step "Waiting for services to be fully ready..."
sleep 10
print_success "Services are ready"
echo ""

# ============================================================================
# POST-DEPLOY VERIFICATION
# ============================================================================
print_header "Verifying Deployment"
echo ""

verify_deployment() {
    local ns=$1
    local label=$2
    local name=$3

    if kubectl get pods -n "$ns" -l "$label" 2>/dev/null | grep -q "Running"; then
        print_success "$name is running"
    else
        print_warning "$name may not be ready yet"
    fi
    return 0
}

verify_deployment "monitoring" "app.kubernetes.io/name=grafana" "Grafana"
verify_deployment "monitoring" "app.kubernetes.io/name=prometheus" "Prometheus"
verify_deployment "monitoring" "app.kubernetes.io/name=loki" "Loki"
verify_deployment "monitoring" "app.kubernetes.io/name=tempo" "Tempo"
verify_deployment "monitoring" "app.kubernetes.io/name=opentelemetry-collector" "OpenTelemetry Collector"
verify_deployment "demo" "app.kubernetes.io/name=otel-demo-app" "Products Service"
verify_deployment "demo" "app.kubernetes.io/name=otel-python-app" "Orders Service"

echo ""

# ============================================================================
# GENERATE SAMPLE TRAFFIC
# ============================================================================
print_header "Generating Sample Observability Data"
echo ""

print_info "Simulating realistic e-commerce traffic patterns..."
print_info "This will create traces, logs, and metrics visible in Grafana"
echo ""

# Function to make HTTP requests
make_request() {
    local host=$1
    local path=$2
    local method=${3:-GET}
    local data=${4:-}
    
    if [ "$method" = "POST" ]; then
        curl -s -X POST \
            -H "Host: $host" \
            -H "Content-Type: application/json" \
            -d "$data" \
            http://localhost${path} > /dev/null 2>&1 || true
    else
        curl -s -H "Host: $host" http://localhost${path} > /dev/null 2>&1 || true
    fi
}

# Simulate realistic e-commerce traffic
for i in {1..30}; do
    # Users browsing products
    make_request "otel-example.localhost" "/api/products"
    make_request "otel-example.localhost" "/api/categories"
    
    # Viewing individual products
    product_id=$((RANDOM % 8 + 1))
    make_request "otel-example.localhost" "/api/products/${product_id}"
    
    # Some users place orders (which calls Products Service from Orders Service)
    if (( RANDOM % 3 == 0 )); then
        order_data="{\"product_id\": ${product_id}, \"quantity\": 1, \"user_id\": \"user-$((RANDOM % 20 + 1))\"}"
        make_request "python-otel-example.localhost" "/api/orders" "POST" "$order_data"
    fi
    
    # Health checks
    make_request "otel-example.localhost" "/health"
    make_request "python-otel-example.localhost" "/health"
    
    # Occasional errors for interesting data
    if (( i % 10 == 0 )); then
        make_request "otel-example.localhost" "/error"
        make_request "python-otel-example.localhost" "/error"
    fi
    
    # Progress indicator
    echo -n "."
    sleep 0.3
done

echo ""
echo ""
print_success "Sample traffic generated successfully"
echo ""

# ============================================================================
# DNS CONFIGURATION REMINDER
# ============================================================================
print_header "Access Information"
echo ""

# Check if entries exist in /etc/hosts
if grep -q "grafana-otel-demo.localhost" /etc/hosts 2>/dev/null && \
   grep -q "otel-example.localhost" /etc/hosts 2>/dev/null && \
   grep -q "python-otel-example.localhost" /etc/hosts 2>/dev/null; then
    print_success "/etc/hosts configuration found"
else
    print_warning "DNS Configuration Required"
    echo ""
    echo -e "Add the following to your ${YELLOW}/etc/hosts${NC} file:"
    echo -e "${GREEN}127.0.0.1 grafana-otel-demo.localhost otel-example.localhost python-otel-example.localhost${NC}"
    echo ""
    echo "Quick command (requires sudo):"
    echo -e "${CYAN}echo '127.0.0.1 grafana-otel-demo.localhost otel-example.localhost python-otel-example.localhost' | sudo tee -a /etc/hosts${NC}"
    echo ""
fi

# ============================================================================
# SETUP COMPLETE
# ============================================================================
print_header "Setup Complete"
echo ""

echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            Your Observability Stack is Ready               ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${CYAN}Grafana Dashboard:${NC}"
echo -e "   URL:      ${BLUE}http://grafana-otel-demo.localhost${NC}"
echo -e "   User:     ${YELLOW}admin${NC}"
echo -e "   Password: ${YELLOW}Mikroways123${NC}"
echo ""

echo -e "${CYAN}Demo Services:${NC}"
echo -e "   Products Service: ${BLUE}http://otel-example.localhost${NC}"
echo -e "   Orders Service:   ${BLUE}http://python-otel-example.localhost${NC}"
echo ""

echo -e "${CYAN}Quick Start:${NC}"
echo -e "   1. Open Grafana and explore the pre-built dashboards"
echo -e "   2. Generate traffic: ${YELLOW}./traffic.sh${NC}"
echo -e "   3. View traces in Tempo, logs in Loki, metrics in Prometheus"
echo ""

echo -e "${CYAN}Documentation:${NC}"
echo -e "   API Reference:    docs/API.md"
echo -e "   Troubleshooting:  docs/TROUBLESHOOTING.md"
echo -e "   Production Guide: docs/PRODUCTION.md"
echo -e "   Cost Analysis:    docs/COST_ANALYSIS.md"
echo ""

echo -e "${CYAN}Cleanup:${NC}"
echo -e "   kind delete cluster --name grafana-otel-demo"
echo ""

print_success "Setup complete. See README.md for next steps."
echo ""


# Create or update .envrc for direnv users
if [ ! -f .envrc ]; then
    cp .envrc-example .envrc 2>/dev/null || true
    if command -v direnv &> /dev/null; then
        direnv allow 2>/dev/null || true
    fi
fi
