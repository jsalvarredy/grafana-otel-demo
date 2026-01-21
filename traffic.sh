#!/bin/bash

# Traffic Generator for OpenTelemetry Observability Demo
# Generates realistic e-commerce traffic patterns for testing and demonstrations

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
PRODUCTS_HOST="${PRODUCTS_HOST:-otel-example.localhost}"
ORDERS_HOST="${ORDERS_HOST:-python-otel-example.localhost}"
BASE_URL="${BASE_URL:-http://localhost}"
MODE="finite"
ITERATIONS=50
DELAY=1
VERBOSE=false

# Statistics
successful_orders=0
failed_orders=0
products_viewed=0
searches=0
errors=0
start_time=$(date +%s)

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

print_header() {
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}================================================================${NC}"
}

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Modes:"
    echo "  --continuous     Run continuously until interrupted (Ctrl+C)"
    echo "  --iterations N   Run for N iterations (default: 50)"
    echo ""
    echo "Speed:"
    echo "  --fast           Fast traffic (0.3s delay)"
    echo "  --slow           Slow traffic (2s delay)"
    echo "  --delay N        Custom delay in seconds"
    echo ""
    echo "Options:"
    echo "  --verbose        Show individual requests"
    echo "  --help           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                      # Run 50 iterations"
    echo "  $0 --iterations 100     # Run 100 iterations"
    echo "  $0 --continuous --fast  # Run continuously with fast traffic"
    echo ""
}

# Make HTTP request
request() {
    local host=$1
    local path=$2
    local method=${3:-GET}
    local data=${4:-}

    local status
    if [ "$method" = "POST" ]; then
        status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
            -H "Host: $host" \
            -H "Content-Type: application/json" \
            -X POST -d "$data" \
            "${BASE_URL}${path}" 2>/dev/null) || status="000"
    else
        status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
            -H "Host: $host" \
            "${BASE_URL}${path}" 2>/dev/null) || status="000"
    fi

    if [ "$VERBOSE" = true ]; then
        if [[ "$status" == "2"* ]]; then
            echo -e "  ${GREEN}[$method]${NC} $path -> $status"
        elif [[ "$status" == "000" ]]; then
            echo -e "  ${RED}[$method]${NC} $path -> timeout"
        else
            echo -e "  ${YELLOW}[$method]${NC} $path -> $status"
        fi
    fi

    echo "$status"
}

# -----------------------------------------------------------------------------
# Traffic Scenarios
# -----------------------------------------------------------------------------

# Browse products and view details
scenario_browse() {
    request "$PRODUCTS_HOST" "/api/products" > /dev/null
    ((products_viewed++)) || true

    local product_id=$((RANDOM % 12 + 1))
    request "$PRODUCTS_HOST" "/api/products/${product_id}" > /dev/null
    ((products_viewed++)) || true

    # Sometimes view recommendations
    if (( RANDOM % 3 == 0 )); then
        request "$PRODUCTS_HOST" "/api/products/${product_id}/recommendations" > /dev/null
    fi
}

# Search and filter products
scenario_search() {
    local terms=("laptop" "keyboard" "wireless" "monitor" "desk" "usb")
    local term=${terms[$((RANDOM % ${#terms[@]}))]}
    request "$PRODUCTS_HOST" "/api/products/search?q=${term}" > /dev/null
    ((searches++)) || true

    local categories=("electronics" "accessories" "stationery")
    local category=${categories[$((RANDOM % 3))]}
    request "$PRODUCTS_HOST" "/api/products?category=${category}&sort=popularity" > /dev/null
}

# Create an order (cross-service call)
scenario_order() {
    local user_id="user-$((RANDOM % 50 + 1))"
    local product_id=$((RANDOM % 12 + 1))
    local quantity=$((RANDOM % 3 + 1))

    # Check product first
    request "$PRODUCTS_HOST" "/api/products/${product_id}" > /dev/null
    ((products_viewed++)) || true

    # Check inventory
    request "$PRODUCTS_HOST" "/api/inventory/${product_id}" > /dev/null

    # Place order
    local data="{\"product_id\": ${product_id}, \"quantity\": ${quantity}, \"user_id\": \"${user_id}\"}"
    local status=$(request "$ORDERS_HOST" "/api/orders" "POST" "$data")

    if [[ "$status" == "201" ]]; then
        ((successful_orders++)) || true
    else
        ((failed_orders++)) || true
    fi
}

# Check order status
scenario_order_status() {
    local user_id="user-$((RANDOM % 50 + 1))"
    local order_id=$(printf "ORD-%05d" $((RANDOM % 100 + 1)))

    request "$ORDERS_HOST" "/api/orders/${order_id}" > /dev/null
    request "$ORDERS_HOST" "/api/orders/user/${user_id}" > /dev/null
}

# Trigger errors (for testing error handling)
scenario_error() {
    request "$PRODUCTS_HOST" "/api/products/99999" > /dev/null
    ((errors++)) || true
}

# Burst traffic (flash sale simulation)
scenario_burst() {
    echo -ne " ${YELLOW}[burst]${NC}"
    local product_id=$((RANDOM % 3 + 1))

    for _ in {1..5}; do
        request "$PRODUCTS_HOST" "/api/products/${product_id}" > /dev/null &
        request "$PRODUCTS_HOST" "/api/inventory/${product_id}" > /dev/null &
    done
    wait

    for _ in {1..3}; do
        local user_id="burst-$((RANDOM % 100))"
        local data="{\"product_id\": ${product_id}, \"quantity\": 1, \"user_id\": \"${user_id}\"}"
        local status=$(request "$ORDERS_HOST" "/api/orders" "POST" "$data")
        if [[ "$status" == "201" ]]; then
            ((successful_orders++)) || true
        fi
    done
}

# Health checks
check_health() {
    request "$PRODUCTS_HOST" "/health" > /dev/null
    request "$ORDERS_HOST" "/health" > /dev/null
}

# -----------------------------------------------------------------------------
# Main Traffic Loop
# -----------------------------------------------------------------------------

run_iteration() {
    local scenario=$((RANDOM % 100))

    # Traffic distribution:
    # 40% - Browse products
    # 25% - Search/filter
    # 20% - Place orders
    # 10% - Check order status
    # 3%  - Errors
    # 2%  - Burst traffic

    if (( scenario < 40 )); then
        scenario_browse
    elif (( scenario < 65 )); then
        scenario_search
    elif (( scenario < 85 )); then
        scenario_order
    elif (( scenario < 95 )); then
        scenario_order_status
    elif (( scenario < 98 )); then
        scenario_error
    else
        scenario_burst
    fi
}

print_stats() {
    local elapsed=$(($(date +%s) - start_time))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))

    echo ""
    echo ""
    print_header "Traffic Generation Complete"
    echo ""
    echo -e "  Duration:        ${CYAN}${mins}m ${secs}s${NC}"
    echo ""
    echo -e "  ${GREEN}Orders${NC}"
    echo -e "    Successful:    ${GREEN}${successful_orders}${NC}"
    echo -e "    Failed:        ${RED}${failed_orders}${NC}"
    echo ""
    echo -e "  ${CYAN}Activity${NC}"
    echo -e "    Products viewed: ${CYAN}${products_viewed}${NC}"
    echo -e "    Searches:        ${CYAN}${searches}${NC}"
    echo -e "    Errors tested:   ${YELLOW}${errors}${NC}"
    echo ""
    echo -e "  View telemetry in Grafana: ${BLUE}http://grafana-otel-demo.localhost${NC}"
    echo ""
}

# Handle Ctrl+C gracefully
trap 'print_stats; exit 0' INT

# -----------------------------------------------------------------------------
# Parse Arguments
# -----------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        --continuous)
            MODE="continuous"
            shift
            ;;
        --iterations)
            MODE="finite"
            ITERATIONS="$2"
            shift 2
            ;;
        --fast)
            DELAY=0.3
            shift
            ;;
        --slow)
            DELAY=2
            shift
            ;;
        --delay)
            DELAY="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------

print_header "Traffic Generator"
echo ""
echo -e "  Products Service: ${CYAN}${PRODUCTS_HOST}${NC}"
echo -e "  Orders Service:   ${CYAN}${ORDERS_HOST}${NC}"
echo -e "  Mode:             ${CYAN}${MODE}${NC}"
echo -e "  Delay:            ${CYAN}${DELAY}s${NC}"
if [ "$MODE" = "finite" ]; then
    echo -e "  Iterations:       ${CYAN}${ITERATIONS}${NC}"
else
    echo -e "  ${YELLOW}Press Ctrl+C to stop${NC}"
fi
echo ""
echo -e "Starting traffic generation..."
echo ""

# Verify services are reachable
echo -n "Checking services"
if ! curl -s -o /dev/null --max-time 5 -H "Host: $PRODUCTS_HOST" "${BASE_URL}/health" 2>/dev/null; then
    echo ""
    echo -e "${RED}Error: Cannot reach Products Service at ${BASE_URL}${NC}"
    echo -e "Make sure the cluster is running and /etc/hosts is configured."
    exit 1
fi
echo -n "."
if ! curl -s -o /dev/null --max-time 5 -H "Host: $ORDERS_HOST" "${BASE_URL}/health" 2>/dev/null; then
    echo ""
    echo -e "${RED}Error: Cannot reach Orders Service at ${BASE_URL}${NC}"
    echo -e "Make sure the cluster is running and /etc/hosts is configured."
    exit 1
fi
echo -e " ${GREEN}OK${NC}"
echo ""

if [ "$MODE" = "continuous" ]; then
    # Continuous mode
    counter=0
    while true; do
        ((counter++)) || true
        run_iteration

        # Progress indicator
        echo -n "."
        if (( counter % 50 == 0 )); then
            echo " [${counter} | orders: ${successful_orders}/${failed_orders}]"
        fi

        # Periodic health check
        if (( counter % 20 == 0 )); then
            check_health
        fi

        sleep "$DELAY"
    done
else
    # Finite mode
    for i in $(seq 1 "$ITERATIONS"); do
        run_iteration

        # Progress bar
        if (( i % 5 == 0 )); then
            percent=$((i * 100 / ITERATIONS))
            filled=$((percent / 2))
            empty=$((50 - filled))
            bar=$(printf '%*s' $filled | tr ' ' '#')
            space=$(printf '%*s' $empty)
            echo -ne "\r  [${bar}${space}] ${percent}%  orders: ${successful_orders}/${failed_orders}"
        fi

        # Periodic health check
        if (( i % 20 == 0 )); then
            check_health
        fi

        sleep "$DELAY"
    done

    print_stats
fi
