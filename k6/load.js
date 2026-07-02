// k6 load test for the Grafana observability demo.
//
// On-brand load generation: k6 is a Grafana product. Metrics are streamed to
// Prometheus via remote write (see k6.sh) and shown on the "k6 Load Testing"
// dashboard in Grafana — and because the requests hit the same instrumented
// services, they also light up the RED dashboards, traces and the service map.
//
// Targets default to the in-cluster service DNS (the Job runs inside the
// cluster). For a local run against the ingress, override the *_URL envs.
import http from 'k6/http';
import { group, sleep } from 'k6';

const PRODUCTS = __ENV.PRODUCTS_URL || 'http://otel-demo-app.demo.svc.cluster.local:8080';
const ORDERS   = __ENV.ORDERS_URL   || 'http://otel-python-app.demo.svc.cluster.local:8080';
const SHIPPING = __ENV.SHIPPING_URL || 'http://shipping-service.demo.svc.cluster.local:8080';

const VUS  = Number(__ENV.VUS || 10);
const RAMP = __ENV.RAMP || '30s';
const HOLD = __ENV.HOLD || '3m';

export const options = {
  scenarios: {
    shoppers: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: RAMP, target: VUS },
        { duration: HOLD, target: VUS },
        { duration: '20s', target: 0 },
      ],
      gracefulRampDown: '10s',
    },
  },
  // Pass/fail criteria — k6 exits non-zero if these are breached.
  thresholds: {
    http_req_failed: ['rate<0.10'],     // < 10% failed requests
    http_req_duration: ['p(95)<800'],   // p95 under 800ms
  },
  tags: { source: 'k6', test: 'ecommerce-load' },
};

function browse() {
  group('browse', () => {
    http.get(`${PRODUCTS}/api/products`, { tags: { name: 'list-products' } });
    const id = Math.floor(Math.random() * 8) + 1;
    http.get(`${PRODUCTS}/api/products/${id}`, { tags: { name: 'get-product' } });
    http.get(`${PRODUCTS}/api/categories`, { tags: { name: 'list-categories' } });
  });
}

function placeOrder() {
  group('order', () => {
    const id = Math.floor(Math.random() * 8) + 1;
    const body = JSON.stringify({ product_id: id, quantity: 1, user_id: `k6-${__VU}` });
    http.post(`${ORDERS}/api/orders`, body, {
      headers: { 'Content-Type': 'application/json' }, tags: { name: 'create-order' },
    });
  });
}

function shipping() {
  group('shipping', () => {
    const body = JSON.stringify({ origin: 'New York', destination: 'Los Angeles', weight: 12 });
    http.post(`${SHIPPING}/api/shipping/quote`, body, {
      headers: { 'Content-Type': 'application/json' }, tags: { name: 'shipping-quote' },
    });
    http.get(`${SHIPPING}/api/`, { tags: { name: 'shipping-info' } });
  });
}

export default function () {
  browse();
  if (Math.random() < 0.4) placeOrder();   // 40% of users order
  if (Math.random() < 0.3) shipping();      // 30% check shipping
  sleep(Math.random() * 1.5 + 0.5);
}
