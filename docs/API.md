# API Reference

This document describes the REST APIs exposed by the demo microservices.

## Products Service (Node.js)

Base URL: `http://products.127.0.0.1.nip.io`

### Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/products` | GET | List products with filtering and sorting |
| `/api/products/search?q=query` | GET | Search by name, description, tags |
| `/api/products/:id` | GET | Get product details |
| `/api/products/:id/reviews` | GET | Get reviews |
| `/api/products/:id/recommendations` | GET | Get similar products |
| `/api/products/:id/purchase` | POST | Process purchase |
| `/api/inventory/:productId` | GET | Check inventory |
| `/api/categories` | GET | List categories |
| `/api/stats` | GET | Service stats |
| `/health` | GET | Health check |

### Query Parameters for `/api/products`

| Parameter | Type | Description |
|-----------|------|-------------|
| `category` | string | Filter by category: electronics, accessories, stationery |
| `minPrice` | number | Minimum price filter |
| `maxPrice` | number | Maximum price filter |
| `minRating` | number | Minimum rating filter |
| `sort` | string | Sort order: price_asc, price_desc, rating, popularity |
| `limit` | number | Pagination limit |
| `offset` | number | Pagination offset |

### Examples

```bash
# List products with filtering
curl "http://products.127.0.0.1.nip.io/api/products?category=electronics&sort=popularity"

# Search products
curl "http://products.127.0.0.1.nip.io/api/products/search?q=wireless"

# Get recommendations
curl "http://products.127.0.0.1.nip.io/api/products/1/recommendations"

# Get reviews
curl "http://products.127.0.0.1.nip.io/api/products/3/reviews"
```

---

## Orders Service (Python)

Base URL: `http://orders.127.0.0.1.nip.io`

### Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/orders` | POST | Create order |
| `/api/orders/:id` | GET | Get order details |
| `/api/orders/:id/track` | GET | Track order status |
| `/api/orders/:id/cancel` | POST | Cancel order |
| `/api/orders/user/:userId` | GET | User order history |
| `/api/stats` | GET | Service stats |
| `/health` | GET | Health check |

### Create Order Request

```json
{
  "product_id": 3,
  "quantity": 2,
  "user_id": "user-42"
}
```

### Examples

```bash
# Create an order (triggers cross-service tracing)
curl -X POST http://orders.127.0.0.1.nip.io/api/orders \
  -H 'Content-Type: application/json' \
  -d '{"product_id": 3, "quantity": 2, "user_id": "user-42"}'

# Track order
curl "http://orders.127.0.0.1.nip.io/api/orders/ORD-00001/track"

# User history
curl "http://orders.127.0.0.1.nip.io/api/orders/user/user-42"

# Service stats
curl "http://orders.127.0.0.1.nip.io/api/stats"
```

---

## Shipping Service (Java + Beyla eBPF)

Base URL: `http://shipping.127.0.0.1.nip.io`

This service has **no OTEL SDK**. All telemetry (traces and metrics) is captured automatically by a Beyla eBPF sidecar.

### Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/` | GET | Service info |
| `/api/health` | GET | Health check |
| `/api/shipping/quote` | POST | Get shipping quote |
| `/api/shipping/create` | POST | Create shipment |
| `/api/shipping/track/:trackingId` | GET | Track shipment |
| `/api/shipping/order/:orderId` | GET | Get shipment by order |
| `/api/slow` | GET | Slow endpoint (for testing) |
| `/api/error` | GET | Error endpoint (for testing) |

### Get Shipping Quote Request

```json
{
  "origin": "New York",
  "destination": "Los Angeles",
  "weight": 25
}
```

### Create Shipment Request

```json
{
  "order_id": "ORD-00042",
  "origin": "New York",
  "destination": "Los Angeles",
  "weight": 25
}
```

### Examples

```bash
# Get a shipping quote
curl -X POST http://shipping.127.0.0.1.nip.io/api/shipping/quote \
  -H 'Content-Type: application/json' \
  -d '{"origin": "New York", "destination": "Los Angeles", "weight": 25}'

# Create a shipment
curl -X POST http://shipping.127.0.0.1.nip.io/api/shipping/create \
  -H 'Content-Type: application/json' \
  -d '{"order_id": "ORD-00042", "origin": "New York", "destination": "Los Angeles", "weight": 25}'

# Track a shipment
curl "http://shipping.127.0.0.1.nip.io/api/shipping/track/SHP-00001"

# Get shipment by order
curl "http://shipping.127.0.0.1.nip.io/api/shipping/order/ORD-00042"

# Health check
curl "http://shipping.127.0.0.1.nip.io/api/health"
```

---

## Metrics Queries (Prometheus)

Use these queries in Grafana -> Explore -> Prometheus:

```promql
# Request rate by service
sum(rate(http_requests_total[5m])) by (exported_job)

# Error rate
sum(rate(http_requests_total{http_status_code=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))

# p95 latency
histogram_quantile(0.95, sum(rate(http_server_duration_bucket[5m])) by (le, endpoint))

# Cache hit ratio
cache_hit_ratio{cache_name="product_cache"}

# Orders created
rate(orders_created_total[5m])

# Revenue
sum(increase(order_revenue_dollars_sum[1h]))

# Cart abandonment
sum(rate(cart_abandonment_total[5m])) by (reason)
```
