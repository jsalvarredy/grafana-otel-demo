#!/bin/bash

# ===================================================================
# Traffic Generation Script for OpenTelemetry Demo
# ===================================================================
# This script generates realistic e-commerce traffic to produce:
# - Traces (distributed tracing across services)
# - Logs (structured logs with trace correlation)
# - Metrics (business and infrastructure metrics)
#
# The script simulates various scenarios:
# - Successful purchases
# - Cart abandonments
# - Payment failures
# - Inventory issues
# - Service errors
# ===================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PRODUCTS_HOST="${PRODUCTS_HOST:-otel-example.localhost}"
ORDERS_HOST="${ORDERS_HOST:-python-otel-example.localhost}"
ITERATIONS="${ITERATIONS:-100}"
DELAY="${DELAY:-0.5}"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   🎲 OpenTelemetry Demo - Traffic Generator              ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}📊 Generating realistic e-commerce traffic patterns...${NC}"
echo -e "${GREEN}   Products Service: ${PRODUCTS_HOST}${NC}"
echo -e "${GREEN}   Orders Service:   ${ORDERS_HOST}${NC}"
echo -e "${GREEN}   Iterations:       ${ITERATIONS}${NC}"
echo ""

# Function to make HTTP requests
make_request() {
    local host=$1
    local path=$2
    local method=${3:-GET}
    local data=${4:-}
    local silent=${5:-true}

    if [ "$silent" = "false" ]; then
        if [ "$method" = "POST" ]; then
            curl -X POST \
                -H "Host: $host" \
                -H "Content-Type: application/json" \
                -d "$data" \
                http://${host}${path} 2>&1
        else
            curl -H "Host: $host" http://${host}${path} 2>&1
        fi
    else
        if [ "$method" = "POST" ]; then
            curl -s -X POST \
                -H "Host: $host" \
                -H "Content-Type: application/json" \
                -d "$data" \
                http://${host}${path} > /dev/null 2>&1 || true
        else
            curl -s -H "Host: $host" http://${host}${path} > /dev/null 2>&1 || true
        fi
    fi
}

# Counters for statistics
successful_orders=0
failed_orders=0
products_viewed=0
errors_triggered=0

# Main traffic generation loop
for i in $(seq 1 $ITERATIONS); do
    # ===================================================================
    # Scenario 1: User browsing products (60% of traffic)
    # ===================================================================
    if (( RANDOM % 10 < 6 )); then
        # Browse all products
        make_request "$PRODUCTS_HOST" "/api/products"
        ((products_viewed++))

        # Browse by category
        categories=("electronics" "accessories" "stationery")
        category=${categories[$((RANDOM % 3))]}
        make_request "$PRODUCTS_HOST" "/api/products?category=$category"

        # View individual product details
        product_id=$((RANDOM % 8 + 1))
        make_request "$PRODUCTS_HOST" "/api/products/${product_id}"
        ((products_viewed++))

        # Check inventory
        make_request "$PRODUCTS_HOST" "/api/inventory/${product_id}"
    fi

    # ===================================================================
    # Scenario 2: Successful order creation (30% of traffic)
    # ===================================================================
    if (( RANDOM % 10 < 3 )); then
        product_id=$((RANDOM % 8 + 1))
        user_id="user-$((RANDOM % 100 + 1))"
        quantity=1

        # Create order through Orders Service (which calls Products Service)
        order_data="{\"product_id\": ${product_id}, \"quantity\": ${quantity}, \"user_id\": \"${user_id}\"}"
        make_request "$ORDERS_HOST" "/api/orders" "POST" "$order_data"
        ((successful_orders++))
    fi

    # ===================================================================
    # Scenario 3: Failed order - Insufficient inventory (5% of traffic)
    # ===================================================================
    if (( RANDOM % 20 == 0 )); then
        # Try to order a large quantity that will likely fail
        product_id=$((RANDOM % 8 + 1))
        user_id="user-$((RANDOM % 100 + 1))"
        quantity=1000  # Intentionally high to trigger inventory failure

        order_data="{\"product_id\": ${product_id}, \"quantity\": ${quantity}, \"user_id\": \"${user_id}\"}"
        make_request "$ORDERS_HOST" "/api/orders" "POST" "$order_data"
        ((failed_orders++))
    fi

    # ===================================================================
    # Scenario 4: Failed order - Invalid product (2% of traffic)
    # ===================================================================
    if (( RANDOM % 50 == 0 )); then
        # Try to order a non-existent product
        product_id=9999
        user_id="user-$((RANDOM % 100 + 1))"

        order_data="{\"product_id\": ${product_id}, \"quantity\": 1, \"user_id\": \"${user_id}\"}"
        make_request "$ORDERS_HOST" "/api/orders" "POST" "$order_data"
        ((failed_orders++))
    fi

    # ===================================================================
    # Scenario 5: Service errors (1% of traffic)
    # ===================================================================
    if (( RANDOM % 100 == 0 )); then
        make_request "$PRODUCTS_HOST" "/error"
        make_request "$ORDERS_HOST" "/error"
        ((errors_triggered++))
    fi

    # ===================================================================
    # Scenario 6: Health checks (every 10 requests)
    # ===================================================================
    if (( i % 10 == 0 )); then
        make_request "$PRODUCTS_HOST" "/health"
        make_request "$ORDERS_HOST" "/health"
    fi

    # ===================================================================
    # Scenario 7: Cart abandonment simulation (15% of traffic)
    # ===================================================================
    # Simulated by viewing products but NOT placing orders
    if (( RANDOM % 10 < 2 )); then
        product_id=$((RANDOM % 8 + 1))
        make_request "$PRODUCTS_HOST" "/api/products/${product_id}"
        # User abandons cart - no order placed
    fi

    # Progress indicator
    if (( i % 10 == 0 )); then
        percent=$((i * 100 / ITERATIONS))
        echo -ne "${GREEN}Progress: [${percent}%] - Orders: ${successful_orders} | Failed: ${failed_orders} | Products Viewed: ${products_viewed}\r${NC}"
    fi

    sleep $DELAY
done

echo ""
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   ✅ Traffic Generation Complete                         ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}📈 Statistics:${NC}"
echo -e "   ${GREEN}✓${NC} Successful Orders:  ${successful_orders}"
echo -e "   ${RED}✗${NC} Failed Orders:      ${failed_orders}"
echo -e "   ${YELLOW}👁${NC}  Products Viewed:    ${products_viewed}"
echo -e "   ${RED}⚠${NC}  Errors Triggered:   ${errors_triggered}"
echo ""
echo -e "${YELLOW}💡 View your data in Grafana:${NC}"
echo -e "   ${BLUE}http://grafana-otel-demo.localhost${NC}"
echo -e ""
echo -e "${YELLOW}📊 Recommended dashboards:${NC}"
echo -e "   • Executive Dashboard - Business Metrics"
echo -e "   • Service Overview Dashboard"
echo -e "   • Distributed Tracing Dashboard"
echo -e "   • Logs Analysis Dashboard"
echo ""
