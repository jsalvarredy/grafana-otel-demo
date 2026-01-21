# Troubleshooting

Common issues and their solutions.

## Pods Not Starting

Check pod status and logs:

```bash
kubectl get pods -n monitoring
kubectl get pods -n demo
kubectl logs -n monitoring <pod-name>
kubectl logs -n demo <pod-name>
```

### Common Causes

1. **Insufficient resources**: Kind cluster may need more memory
2. **Image pull errors**: Check if images were loaded into Kind
3. **Config errors**: Check ConfigMaps and Secrets

---

## Can't Access Grafana

### 1. Check Ingress Controller

```bash
kubectl get pods -n ingress-nginx
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx
```

### 2. Verify /etc/hosts Entry

```bash
grep grafana-otel-demo.localhost /etc/hosts
```

Should show: `127.0.0.1 grafana-otel-demo.localhost`

### 3. Use Port-Forward as Alternative

```bash
kubectl port-forward -n monitoring svc/grafana 3000:80
# Access http://localhost:3000
```

---

## No Data in Dashboards

### 1. Check OpenTelemetry Collector

```bash
kubectl get pods -n monitoring | grep otel-collector
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector
```

### 2. Generate Traffic

```bash
./quick-traffic.sh
```

### 3. Check Service Logs

```bash
kubectl logs -n demo -l app.kubernetes.io/name=otel-demo-app
kubectl logs -n demo -l app.kubernetes.io/name=otel-python-app
```

### 4. Verify Data Sources in Grafana

Go to Grafana -> Configuration -> Data Sources and test each connection.

---

## Traces Not Appearing in Tempo

### 1. Check Tempo Pod

```bash
kubectl get pods -n monitoring | grep tempo
kubectl logs -n monitoring -l app.kubernetes.io/name=tempo
```

### 2. Verify OTLP Receiver

The collector should be receiving traces on port 4317 (gRPC) or 4318 (HTTP).

### 3. Check Trace Context Propagation

Make sure services are propagating trace context. Create an order to test:

```bash
curl -X POST http://python-otel-example.localhost/api/orders \
  -H 'Content-Type: application/json' \
  -d '{"product_id": 1, "quantity": 1, "user_id": "test-user"}'
```

---

## Logs Not Appearing in Loki

### 1. Check Loki Pod

```bash
kubectl get pods -n monitoring | grep loki
kubectl logs -n monitoring -l app.kubernetes.io/name=loki
```

### 2. Test LogQL Query

In Grafana -> Explore -> Loki:

```logql
{service_name=~".+"}
```

---

## Metrics Not Appearing in Prometheus

### 1. Check Prometheus Pod

```bash
kubectl get pods -n monitoring | grep prometheus
```

### 2. Verify Targets

Access Prometheus targets:

```bash
kubectl port-forward -n monitoring svc/prometheus-server 9090:80
# Open http://localhost:9090/targets
```

### 3. Test PromQL Query

In Grafana -> Explore -> Prometheus:

```promql
up
```

---

## Kind Cluster Issues

### Cluster Won't Start

```bash
# Delete and recreate
kind delete cluster --name grafana-otel-demo
./setup.sh
```

### Docker Resource Limits

Ensure Docker has enough resources (recommended: 4GB+ RAM, 2+ CPUs).

---

## Cleanup

```bash
kind delete cluster --name grafana-otel-demo
sudo sed -i '/grafana-otel-demo.localhost/d' /etc/hosts
```
