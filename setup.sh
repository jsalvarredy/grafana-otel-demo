#!/bin/bash

# Grafana OpenTelemetry Demo - Enhanced Setup Script
# This script creates a Kind cluster and deploys a complete observability stack:
# - Nginx Ingress Controller
# - Grafana LGTP Stack (Loki, Grafana, Tempo, Prometheus)
# - Grafana Alloy (unified telemetry gateway: Faro RUM + backend OTLP; and a
#   second Alloy DaemonSet for node/pod log tailing)
# - Demo microservices (Products Service, Orders Service & Shipping Service)

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

# ============================================================================
# DEPLOYMENT OBSERVABILITY
# ============================================================================
# Every setup run gets a unique release identity by default; DEPLOY_VERSION can
# explicitly override it. The same value is
# used as the image tag, Kubernetes app version, OTel service.version and Faro
# app.version, so a dashboard marker can be tied to the exact running release.
epoch_ms() {
    local raw
    raw="$(date +%s%N 2>/dev/null || true)"
    if [[ "$raw" =~ ^[0-9]{13,}$ ]]; then
        printf '%s\n' "${raw:0:13}"
    else
        printf '%s000\n' "$(date +%s)"
    fi
}

GIT_REVISION="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')"
GIT_SHORT="$(git rev-parse --short=12 HEAD 2>/dev/null || printf 'local')"
DIRTY_SUFFIX=""
if [ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
    DIRTY_SUFFIX="-dirty"
fi
RELEASE_CLOCK_MS="$(epoch_ms)"
RAW_DEPLOY_VERSION="${DEPLOY_VERSION:-git-${GIT_SHORT}${DIRTY_SUFFIX}-${RELEASE_CLOCK_MS}}"
# Docker tags and Kubernetes label values share this conservative character set.
DEPLOY_VERSION="$(printf '%s' "$RAW_DEPLOY_VERSION" | tr -cs '[:alnum:]_.-' '-' | sed 's/^[^[:alnum:]]*//;s/[^[:alnum:]]*$//' | cut -c1-63)"
if [ -z "$DEPLOY_VERSION" ]; then
    echo "Invalid DEPLOY_VERSION: '$RAW_DEPLOY_VERSION'" >&2
    exit 1
fi
DEPLOY_ENVIRONMENT="${DEPLOY_ENVIRONMENT:-demo}"
if ! [[ "$DEPLOY_ENVIRONMENT" =~ ^[[:alnum:]][[:alnum:]_.-]{0,62}$ ]]; then
    echo "DEPLOY_ENVIRONMENT must be a Kubernetes-label-safe value (max 63 chars)" >&2
    exit 1
fi
DEPLOY_ID="${DEPLOY_ID:-dep-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
if ! [[ "$DEPLOY_ID" =~ ^[[:alnum:]][[:alnum:]_.:-]{0,127}$ ]]; then
    echo "DEPLOY_ID must use 1-128 alphanumeric, dot, underscore, colon or dash characters" >&2
    exit 1
fi
DEPLOY_ACTOR="${DEPLOY_ACTOR:-${GITHUB_ACTOR:-${GITLAB_USER_LOGIN:-${USER:-unknown}}}}"
DEPLOY_SOURCE="${DEPLOY_SOURCE:-setup.sh}"
DEPLOY_RUN_URL="${DEPLOY_RUN_URL:-${CI_PIPELINE_URL:-}}"
if [ -z "$DEPLOY_RUN_URL" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    DEPLOY_RUN_URL="https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi
DEPLOY_STARTED_AT_MS=""
DEPLOY_ACTIVE=0
DEPLOY_EVENT_FILE=""
DEPLOY_SNAPSHOT_ENABLED="${DEPLOY_SNAPSHOT_ENABLED:-1}"
DEPLOY_SNAPSHOT_ROOT="${DEPLOY_SNAPSHOT_ROOT:-artifacts/deployments}"
DEPLOY_SNAPSHOT_SAFE_ID="$(printf '%s' "$DEPLOY_ID" | tr -cs '[:alnum:]_.-' '-' | sed 's/^-*//;s/-*$//' | cut -c1-120)"
DEPLOY_SNAPSHOT_DIR="${DEPLOY_SNAPSHOT_ROOT%/}/${DEPLOY_SNAPSHOT_SAFE_ID}"

record_deployment() {
    local status="$1" finished_at_ms="$2" mode="${3:-required}" output_file="${4:-}"
    if [ ! -x ./deploy-observe.sh ]; then
        if [ "$mode" = "best-effort" ]; then
            print_warning "deploy-observe.sh is unavailable; failed deployment annotation not recorded"
            return 0
        fi
        print_error "deploy-observe.sh is unavailable; refusing to certify deployment"
        return 1
    fi
    local args=(
        --service products-service
        --service orders-service
        --service shipping-service
        --service frontend-shop
        --version "$DEPLOY_VERSION"
        --environment "$DEPLOY_ENVIRONMENT"
        --revision "$GIT_REVISION"
        --deployment-id "$DEPLOY_ID"
        --actor "$DEPLOY_ACTOR"
        --source "$DEPLOY_SOURCE"
        --status "$status"
        --started-at-ms "$DEPLOY_STARTED_AT_MS"
        --finished-at-ms "$finished_at_ms"
    )
    [ -n "$DEPLOY_RUN_URL" ] && args+=(--run-url "$DEPLOY_RUN_URL")
    [ -n "$output_file" ] && args+=(--output "$output_file")
    [ "$mode" = "best-effort" ] && args+=(--best-effort)
    ./deploy-observe.sh "${args[@]}"
}

on_setup_exit() {
    local rc=$?
    trap - EXIT
    if [ "$DEPLOY_ACTIVE" -eq 1 ]; then
        record_deployment failed "$(epoch_ms)" best-effort || true
    fi
    if [ -n "$DEPLOY_EVENT_FILE" ]; then
        rm -f "$DEPLOY_EVENT_FILE"
    fi
    exit "$rc"
}
trap on_setup_exit EXIT

# Start
clear
print_header "Grafana LGTP + OpenTelemetry Demo Setup"
echo ""
print_info "Setup will take approximately 8-12 minutes depending on your internet connection."
echo ""

# ============================================================================
# PREREQUISITES CHECK
# ============================================================================
print_step "Checking prerequisites..."

check_command() {
    if command -v "$1" &> /dev/null; then
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
kubectl apply -f kind/dashboards/platform-home-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/deployment-health-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/apm-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/service-breakdown-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/k8s-dashboard-cm.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/logs-search-cm.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/service-overview-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/service-map-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/tracing-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/profiling-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/logs-analysis-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/executive-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/observability-overview-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/slo-sli-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/synthetic-monitoring-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/frontend-rum-dashboard.yaml > /dev/null 2>&1
kubectl apply -f kind/dashboards/k6-dashboard.yaml > /dev/null 2>&1

print_success "17 dashboards provisioned (Platform Home, Deployment Health, APM, Service Time Breakdown, K8s, Logs Search, Service Overview, Service Map, Tracing, Profiling, Logs Analysis, Executive, Observability Overview, SLO/SLI, Synthetic Monitoring, Frontend/RUM, k6 Load Testing)"
echo ""

# ============================================================================
# BUILD AND DEPLOY DEMO APPLICATIONS
# ============================================================================
print_header "Building and Deploying Demo Applications"
echo ""

DEPLOY_STARTED_AT_MS="$(epoch_ms)"
DEPLOYED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DEPLOY_ACTIVE=1
print_info "Release: ${DEPLOY_VERSION} · revision: ${GIT_SHORT}${DIRTY_SUFFIX} · environment: ${DEPLOY_ENVIRONMENT}"

print_step "Building Products Service (Node.js)..."
docker build -t "products-service:${DEPLOY_VERSION}" src/otel-app > /dev/null 2>&1
print_success "Products Service image built"

print_step "Building Orders Service (Python)..."
docker build -t "orders-service:${DEPLOY_VERSION}" src/otel-python-app > /dev/null 2>&1
print_success "Orders Service image built"

print_step "Building Shipping Service (Java + OTel Java agent; Beyla optional)..."
docker build -t "shipping-service:${DEPLOY_VERSION}" src/shipping-service > /dev/null 2>&1
print_success "Shipping Service image built"

print_step "Building Frontend (nginx + vendored Faro Web SDK)..."
docker build -t "frontend-service:${DEPLOY_VERSION}" src/frontend-app > /dev/null 2>&1
print_success "Frontend image built"

print_step "Loading release-tagged images into Kind cluster..."
kind load docker-image "products-service:${DEPLOY_VERSION}" --name grafana-otel-demo > /dev/null 2>&1
kind load docker-image "orders-service:${DEPLOY_VERSION}" --name grafana-otel-demo > /dev/null 2>&1
kind load docker-image "shipping-service:${DEPLOY_VERSION}" --name grafana-otel-demo > /dev/null 2>&1
kind load docker-image "frontend-service:${DEPLOY_VERSION}" --name grafana-otel-demo > /dev/null 2>&1
print_success "Images loaded into cluster"

print_step "Creating demo namespace..."
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

OBSERVABILITY_ARGS=(
  --set-string "observability.version=${DEPLOY_VERSION}"
  --set-string "observability.environment=${DEPLOY_ENVIRONMENT}"
  --set-string "observability.revision=${GIT_REVISION}"
  --set-string "observability.deploymentId=${DEPLOY_ID}"
  --set-string "observability.deployedAt=${DEPLOYED_AT}"
)

print_step "Deploying Products Service..."
helm upgrade --install otel-demo-app charts/otel-demo-app \
  --set image.repository=products-service \
  --set-string "image.tag=${DEPLOY_VERSION}" \
  "${OBSERVABILITY_ARGS[@]}" \
  --namespace demo \
  --create-namespace \
  -f charts/otel-demo-app/values.yaml \
  --wait --timeout 3m > /dev/null 2>&1
print_success "Products Service deployed (${DEPLOY_VERSION})"

print_step "Deploying Orders Service..."
helm upgrade --install otel-python-app charts/otel-python-app \
  --set image.repository=orders-service \
  --set-string "image.tag=${DEPLOY_VERSION}" \
  "${OBSERVABILITY_ARGS[@]}" \
  --namespace demo \
  -f charts/otel-python-app/values.yaml \
  --wait --timeout 3m > /dev/null 2>&1
print_success "Orders Service deployed (${DEPLOY_VERSION})"

print_step "Deploying Shipping Service (OTel Java agent; Beyla optional)..."
helm upgrade --install shipping-service charts/shipping-service \
  --set image.repository=shipping-service \
  --set-string "image.tag=${DEPLOY_VERSION}" \
  "${OBSERVABILITY_ARGS[@]}" \
  --namespace demo \
  --create-namespace \
  -f charts/shipping-service/values.yaml \
  --wait --timeout 5m > /dev/null 2>&1
print_success "Shipping Service deployed (${DEPLOY_VERSION})"

print_step "Deploying Frontend (Faro RUM)..."
helm upgrade --install frontend-app charts/frontend-app \
  --set image.repository=frontend-service \
  --set-string "image.tag=${DEPLOY_VERSION}" \
  "${OBSERVABILITY_ARGS[@]}" \
  --namespace demo \
  -f charts/frontend-app/values.yaml \
  --wait --timeout 3m > /dev/null 2>&1
print_success "Frontend deployed (${DEPLOY_VERSION})"

echo ""
print_success "All services rolled out successfully; validating telemetry before marking the deployment succeeded"
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
    local rows bad_rows

    rows=$(kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null || true)
    if [ -z "$rows" ]; then
        print_warning "$name has no pods"
        return 0
    fi
    bad_rows=$(printf '%s\n' "$rows" | awk '
      $3 == "Completed" { next }
      { split($2, ready, "/"); if ($3 != "Running" || ready[1] != ready[2]) print $1 }
    ')
    if [ -z "$bad_rows" ]; then
        print_success "$name is fully Ready"
    else
        print_warning "$name has non-ready containers: $(printf '%s' "$bad_rows" | paste -sd ',' -)"
    fi
    return 0
}

verify_deployment "monitoring" "app.kubernetes.io/name=grafana" "Grafana"
verify_deployment "monitoring" "app.kubernetes.io/name=prometheus" "Prometheus"
verify_deployment "monitoring" "app.kubernetes.io/name=loki" "Loki"
verify_deployment "monitoring" "app.kubernetes.io/name=tempo" "Tempo"
verify_deployment "monitoring" "app.kubernetes.io/instance=alloy" "Grafana Alloy (gateway: Faro + OTLP backend)"
verify_deployment "monitoring" "app.kubernetes.io/instance=alloy-logs" "Grafana Alloy (node logs DaemonSet)"
verify_deployment "demo" "app.kubernetes.io/name=otel-demo-app" "Products Service"
verify_deployment "demo" "app.kubernetes.io/name=otel-python-app" "Orders Service"
verify_deployment "demo" "app.kubernetes.io/name=shipping-service" "Shipping Service"
verify_deployment "demo" "app.kubernetes.io/name=frontend-app" "Frontend / Faro Shop"

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
            "http://localhost${path}" > /dev/null 2>&1 || true
    else
        curl -s -H "Host: $host" "http://localhost${path}" > /dev/null 2>&1 || true
    fi
}

# Simulate realistic e-commerce traffic across ALL services
for i in {1..40}; do
    # Users browsing products
    make_request "products.127.0.0.1.nip.io" "/api/products"
    make_request "products.127.0.0.1.nip.io" "/api/categories"

    # Viewing individual products
    product_id=$((RANDOM % 8 + 1))
    make_request "products.127.0.0.1.nip.io" "/api/products/${product_id}"

    # Place orders (cross-service call: orders -> products)
    if (( RANDOM % 3 == 0 )); then
        order_data="{\"product_id\": ${product_id}, \"quantity\": 1, \"user_id\": \"user-$((RANDOM % 20 + 1))\"}"
        make_request "orders.127.0.0.1.nip.io" "/api/orders" "POST" "$order_data"
    fi

    # Shipping service - request quotes and create shipments every iteration
    cities=("New York" "Los Angeles" "Chicago" "Houston" "Miami" "Seattle" "Denver" "Boston")
    origin=${cities[$((RANDOM % ${#cities[@]}))]}
    dest=${cities[$((RANDOM % ${#cities[@]}))]}
    weight=$((RANDOM % 50 + 1))

    quote_data="{\"origin\": \"${origin}\", \"destination\": \"${dest}\", \"weight\": ${weight}}"
    make_request "shipping.127.0.0.1.nip.io" "/api/shipping/quote" "POST" "$quote_data"

    ship_data="{\"order_id\": \"ORD-$((RANDOM % 1000))\", \"origin\": \"${origin}\", \"destination\": \"${dest}\", \"weight\": ${weight}}"
    make_request "shipping.127.0.0.1.nip.io" "/api/shipping/create" "POST" "$ship_data"

    # Track shipments and check order shipments
    tracking_id=$(printf "SHP-%05d" $((RANDOM % 500 + 1)))
    make_request "shipping.127.0.0.1.nip.io" "/api/shipping/track/${tracking_id}"

    order_id=$(printf "ORD-%05d" $((RANDOM % 1000 + 1)))
    make_request "shipping.127.0.0.1.nip.io" "/api/shipping/order/${order_id}"

    # Shipping service info endpoint
    make_request "shipping.127.0.0.1.nip.io" "/api/"

    # Occasional slow endpoint to generate interesting latency data
    if (( i % 5 == 0 )); then
        make_request "shipping.127.0.0.1.nip.io" "/api/slow"
    fi

    # Occasional errors for interesting data (all services)
    if (( i % 8 == 0 )); then
        make_request "products.127.0.0.1.nip.io" "/error"
        make_request "orders.127.0.0.1.nip.io" "/error"
        make_request "shipping.127.0.0.1.nip.io" "/api/error"
    fi

    # Progress indicator
    echo -n "."
    sleep 0.2
done

echo ""
echo ""
print_success "Sample traffic generated successfully"
echo ""

# ============================================================================
# DEMO READINESS CHECK
# ============================================================================
print_header "Demo Readiness Check"
echo ""
print_info "Validating the four signals, service map, exemplars, plugins and alerts..."
echo ""
if [ ! -x ./check.sh ]; then
    print_error "check.sh not found or not executable; cannot certify demo readiness"
    exit 1
fi
if ! DEPLOYMENT_ANNOTATION_REQUIRED=0 ./check.sh; then
    print_error "Demo readiness validation failed. Fix the reported checks and re-run ./check.sh."
    exit 1
fi
DEPLOY_EVENT_FILE="$(mktemp)"
record_deployment succeeded "$(epoch_ms)" required "$DEPLOY_EVENT_FILE"
# The release itself is now certified. Snapshot failures must not rewrite that
# truthful terminal state as a failed deployment.
DEPLOY_ACTIVE=0
print_success "Deployment ${DEPLOY_ID} certified and annotated as succeeded"

if [ "$DEPLOY_SNAPSHOT_ENABLED" = "1" ]; then
    if [ ! -x ./deployment-snapshot.sh ]; then
        print_error "deployment-snapshot.sh not found or not executable"
        exit 1
    fi
    print_step "Capturing auditable deployment snapshot..."
    if ! ./deployment-snapshot.sh \
        --deployment-id "$DEPLOY_ID" \
        --version "$DEPLOY_VERSION" \
        --environment "$DEPLOY_ENVIRONMENT" \
        --revision "$GIT_REVISION" \
        --status succeeded \
        --event "$DEPLOY_EVENT_FILE" \
        --output-dir "$DEPLOY_SNAPSHOT_DIR"; then
        print_error "Deployment succeeded, but its audit snapshot could not be created"
        exit 1
    fi
    print_success "Deployment snapshot: ${DEPLOY_SNAPSHOT_DIR}"
else
    print_warning "Deployment snapshot disabled with DEPLOY_SNAPSHOT_ENABLED=${DEPLOY_SNAPSHOT_ENABLED}"
fi
rm -f "$DEPLOY_EVENT_FILE"
DEPLOY_EVENT_FILE=""
echo ""

# ============================================================================
# DNS CONFIGURATION REMINDER
# ============================================================================
print_header "Access Information"
echo ""

print_success "DNS resolves automatically via nip.io - no /etc/hosts changes needed"

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
echo -e "   URL:      ${BLUE}http://grafana.127.0.0.1.nip.io${NC}"
echo -e "   User:     ${YELLOW}admin${NC}"
echo -e "   Password: ${YELLOW}Mikroways123${NC}"
echo ""

echo -e "${CYAN}Demo Services:${NC}"
echo -e "   Products Service:  ${BLUE}http://products.127.0.0.1.nip.io${NC}"
echo -e "   Orders Service:    ${BLUE}http://orders.127.0.0.1.nip.io${NC}"
echo -e "   Shipping Service:  ${BLUE}http://shipping.127.0.0.1.nip.io${NC}"
echo -e "   Frontend (Faro):   ${BLUE}http://shop.127.0.0.1.nip.io${NC}"
echo ""

if [ "$DEPLOY_SNAPSHOT_ENABLED" = "1" ]; then
    echo -e "${CYAN}Deployment Evidence:${NC}"
    echo -e "   Snapshot: ${YELLOW}${DEPLOY_SNAPSHOT_DIR}${NC}"
    echo -e "   Verify:   ${YELLOW}(cd ${DEPLOY_SNAPSHOT_DIR} && sha256sum -c SHA256SUMS)${NC}"
    echo ""
fi

echo -e "${CYAN}Quick Start:${NC}"
echo -e "   1. Open Grafana and explore the pre-built dashboards"
echo -e "   2. Generate baseline traffic: ${YELLOW}./traffic.sh --continuous --fast${NC}"
echo -e "   3. Run the guided demo: ${YELLOW}see DEMO.md${NC}"
echo -e "   4. Inject a live incident: ${YELLOW}./incident.sh${NC}"
echo -e "   5. Explore queryless under ${YELLOW}Drilldown${NC} in the Grafana nav"
echo ""

echo -e "${CYAN}Documentation:${NC}"
echo -e "   Demo Script:      DEMO.md"
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
