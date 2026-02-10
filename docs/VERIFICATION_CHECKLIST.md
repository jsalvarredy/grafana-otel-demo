# Metrics Verification Checklist

## ✅ Verification Status

Use this checklist to verify all metrics are working correctly.

---

## 1. Prometheus Metrics (Explore)

Access: **Grafana → Explore → Prometheus**

### Core Infrastructure Metrics

- [ ] **http_requests_total** - HTTP request counter
  ```promql
  sum(rate(http_requests_total[5m])) by (service_name)
  ```
  **Expected:** 2 lines (products-service, orders-service)

- [ ] **http_server_duration** - Request latency histogram
  ```promql
  histogram_quantile(0.95, sum(rate(http_server_duration_milliseconds_bucket[5m])) by (le, service_name))
  ```
  **Expected:** Values between 50-200ms typically

- [ ] **Status code breakdown**
  ```promql
  sum(rate(http_requests_total[5m])) by (service_name, http_status_code)
  ```
  **Expected:** Mostly 200s, some 404s, minimal 5xxs

### Business Metrics - Products Service

- [ ] **products_viewed_total** - Product view counter
  ```promql
  rate(products_viewed_total[5m])
  ```
  **Expected:** Positive rate

- [ ] **purchases_total** - Purchase counter
  ```promql
  rate(purchases_total[5m])
  ```
  **Expected:** Lower than views (conversion funnel)

- [ ] **cart_abandonment_total** - Abandoned carts
  ```promql
  rate(cart_abandonment_total[5m])
  ```
  **Expected:** Some abandonments

- [ ] **checkout_success_total** - Successful checkouts
  ```promql
  rate(checkout_success_total[5m])
  ```
  **Expected:** Positive rate

- [ ] **revenue_at_risk_dollars** - Revenue at risk
  ```promql
  sum(rate(revenue_at_risk_dollars_total[5m])) * 60
  ```
  **Expected:** Dollar value per minute

- [ ] **customer_experience_score** - CX score (0-100)
  ```promql
  avg(customer_experience_score)
  ```
  **Expected:** Score 70-100 typically

### Business Metrics - Orders Service

- [ ] **orders_created_total** - Orders created
  ```promql
  rate(orders_created_total[5m])
  ```
  **Expected:** Positive rate

- [ ] **order_revenue_dollars** - Order revenue
  ```promql
  sum(rate(order_revenue_dollars_sum[5m])) * 60
  ```
  **Expected:** Revenue per minute

- [ ] **failed_transaction_revenue_lost** - Lost revenue
  ```promql
  sum(rate(failed_transaction_revenue_lost_total[5m])) * 60
  ```
  **Expected:** Some loss from failures

- [ ] **order_processing_time_seconds** - Processing time
  ```promql
  histogram_quantile(0.95, sum(rate(order_processing_time_seconds_bucket[5m])) by (le))
  ```
  **Expected:** < 2 seconds typically

- [ ] **sla_violation_events** - SLA violations
  ```promql
  rate(sla_violation_events_total[5m])
  ```
  **Expected:** Low rate (< 1% of requests)

---

## 2. Executive Dashboard

Access: **Grafana → Dashboards → Executive Dashboard - Business Metrics**

### Business Impact Summary

- [ ] **Revenue at Risk ($/min)** - Shows dollar amount
  - Green: < $50/min
  - Yellow: $50-100/min
  - Red: > $100/min

- [ ] **Affected Customers** - Shows customer count
  - Based on cart abandonments

- [ ] **Avg Order Processing Time** - Shows seconds
  - Green: < 1s
  - Yellow: 1-2s
  - Red: > 2s

- [ ] **Customer Experience Score** - Shows 0-100
  - Green: > 85
  - Yellow: 70-85
  - Red: < 70

### SLA/SLO Compliance

- [ ] **Availability SLA** - Shows percentage
  - Target: 99.9%
  - Formula: (1 - 5xx errors / total requests) * 100

- [ ] **Latency SLO p95** - Shows milliseconds
  - Target: < 200ms
  - Based on order_processing_time_seconds

- [ ] **Error Budget Remaining** - Shows percentage
  - Shows remaining budget for current hour

- [ ] **SLA Violations by Reason** - Pie chart
  - Breakdown by failure reason

### Service Health

- [ ] **Service Status Matrix** - Table with color coding
  - Shows health % per service
  - Color: Red < 90%, Yellow 90-95%, Green > 95%

- [ ] **Top 3 Services by Error Rate** - Time series
  - Shows services with highest error rates

- [ ] **Traffic Distribution** - Pie chart
  - Shows request distribution across services

### Customer Experience

- [ ] **Checkout Success Rate** - Shows percentage
  - Target: > 95%
  - Formula: (success / attempts) * 100

- [ ] **Cart Abandonment Rate** - Shows percentage
  - Lower is better
  - Formula: (abandonments / (abandonments + success)) * 100

- [ ] **Avg Order Processing Time** - Shows seconds
  - Average time to process orders

- [ ] **Revenue vs Lost Revenue** - Time series
  - Green line: Successful revenue
  - Red line: Lost revenue from failures

### Operational Efficiency

- [ ] **Incidents Detected (Last 7 Days)** - Shows count
  - Total SLA violations in past week

- [ ] **Avg Time to Detection** - Shows seconds
  - Time to detect failed orders

- [ ] **MTTR** - Shows seconds
  - Mean Time To Resolution

- [ ] **Estimated Cost Savings** - Shows dollars
  - Revenue saved through early detection

---

## 3. Other Dashboards

### Service Overview Dashboard

- [ ] Request Rate panel shows data
- [ ] Error Rate gauge shows percentage
- [ ] Response Latency shows p50/p95/p99
- [ ] Top Endpoints chart populated
- [ ] Endpoints Statistics table has rows

### Distributed Tracing Dashboard

- [ ] Recent Errors (Orders) shows traces
- [ ] Slow Traces > 500ms shows traces
- [ ] Recent Errors (Products) shows traces
- [ ] All Traces Explorer is clickable

### Logs Analysis Dashboard

- [ ] Global Traffic Volume shows bars
- [ ] Live Logs: orders-service shows entries
- [ ] Live Logs: products-service shows entries
- [ ] Logs have trace_id fields (clickable)

---

## 4. Trace-Log-Metric Correlation

### Test Correlation Flow

1. [ ] Find a trace in Distributed Tracing Dashboard
2. [ ] Click on trace ID
3. [ ] Click "Logs for this span" button
4. [ ] Verify logs appear with matching trace_id
5. [ ] Click on service name
6. [ ] Verify metrics appear for that service

---

## 5. Troubleshooting

### If Metrics Are Empty

**Check 1:** Time range in Grafana
- [ ] Set to "Last 15 minutes" or "Last 1 hour"

**Check 2:** OTEL Collector logs
```bash
kubectl logs -n monitoring deployment/otel-collector-opentelemetry-collector --tail=50 | grep -i error
```
- [ ] No "duplicate label" errors
- [ ] No "failed to convert metric" errors

**Check 3:** Application pods running
```bash
kubectl get pods -n demo
```
- [ ] Both pods Running
- [ ] No CrashLoopBackOff

**Check 4:** Generate more traffic
```bash
./generate-traffic.sh
# or
./quick-traffic.sh
```
- [ ] Wait 30 seconds
- [ ] Refresh Grafana

**Check 5:** Prometheus targets
```bash
kubectl port-forward -n monitoring svc/prometheus-server 9090:80
# Open http://localhost:9090/targets
```
- [ ] otel-collector target is UP
- [ ] No scraping errors

---

## 6. Expected Metric Behavior

### Normal Operation

- **Request Rate:** 0.5-2 req/sec per service (idle)
- **Error Rate:** < 1%
- **p95 Latency:** 50-200ms
- **Checkout Success:** > 90%
- **Cart Abandonment:** 10-30%
- **Customer Experience Score:** 70-95

### During Traffic Generation

- **Request Rate:** 5-20 req/sec per service
- **Error Rate:** 1-5% (simulated failures)
- **p95 Latency:** 100-500ms
- **Checkout Success:** 70-95%
- **Cart Abandonment:** 15-40%
- **SLA Violations:** 0-5 per minute

---

## 7. Success Criteria

✅ **Metrics are working if:**

1. At least 10 different metric names appear in Prometheus
2. Executive Dashboard shows data in > 80% of panels
3. Service Overview Dashboard shows non-zero values
4. Traces link to logs (trace_id correlation works)
5. No errors in OTEL Collector logs

---

## 8. Next Steps After Verification

Once all checks pass:

1. **Make changes permanent:**
   - Rebuild Docker images with corrected code
   - Update Helm chart values
   - Push images to registry

2. **Add alerting:**
   - Configure AlertManager
   - Create alert rules for critical metrics
   - Set up notification channels (Slack, email)

3. **Expand metrics:**
   - Add database performance metrics
   - Add cache hit/miss ratios
   - Add custom business KPIs

4. **Optimize:**
   - Tune histogram buckets for your latency SLOs
   - Adjust metric cardinality if needed
   - Implement sampling for high-volume services

---

**Last Updated:** 2026-01-13
**Version:** 1.0
