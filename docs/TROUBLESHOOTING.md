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

### 2. Verify DNS Resolution

```bash
# nip.io should resolve automatically to 127.0.0.1
nslookup grafana.127.0.0.1.nip.io
```

### 3. Use Port-Forward as Alternative

```bash
kubectl port-forward -n monitoring svc/grafana 3000:80
# Access http://localhost:3000
```

---

## No Data in Dashboards

### 1. Check Grafana Alloy (telemetry pipeline)

Two Alloy releases run in the cluster: `alloy` (the OTLP/Faro gateway,
a Deployment) and `alloy-logs` (the node log collector, a DaemonSet).

```bash
kubectl get pods -n monitoring | grep alloy
kubectl logs -n monitoring deployment/alloy --tail=50
kubectl logs -n monitoring -l app.kubernetes.io/instance=alloy-logs --tail=50
```

### 2. Generate Traffic

```bash
./traffic.sh --iterations 50
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

Alloy should be receiving traces on port 4317 (gRPC) or 4318 (HTTP) of the
`alloy` Service in the `monitoring` namespace.

### 3. Check Trace Context Propagation

Make sure services are propagating trace context. Create an order to test:

```bash
curl -X POST http://orders.127.0.0.1.nip.io/api/orders \
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

### No exemplars in Prometheus for an app

Alloy (`otelcol.exporter.prometheus` -> `prometheus.remote_write`) forwards
exemplars on the `_bucket` series; Prometheus needs `--enable-feature=exemplar-storage`.

```bash
curl -s "http://localhost:9090/api/v1/query_exemplars?query=http_server_request_duration_seconds_bucket{service_name=\"shipping-service\"}&start=$(($(date +%s)-600))&end=$(date +%s)"
```

If empty, the app SDK is not emitting exemplars (Node/Python need an exemplar
filter wired in the SDK); exemplars also require a sampled span. Exemplars only
exist on histogram `_bucket` series, not `_count`/`_sum`.

The trace label name depends on the producer: Tempo's span metrics use
`traceID`, while app exemplars that pass through Alloy use `trace_id` (plus
`span_id`). `check.sh` accepts both and prints which one it found. When it
fails it also prints the number of exemplar series returned: `0` means no
exemplars were emitted (SDK filter, unsampled spans, Beyla), while `>0` means
exemplars exist but carry an unrecognized trace label.

### check.sh: "No succeeded Grafana annotation..." / "Latest annotation ... is failed"

`setup.sh` runs `check.sh` with the annotation check deferred, and only records
a `succeeded` deployment annotation after every readiness check passes. If a
check fails, setup records a `failed` annotation for that deployment ID. A later
plain `./check.sh` looks for a `succeeded` annotation for the running
deployment ID and version, so it keeps failing even after you fix the cause:
`check.sh` only reads annotations, it never writes them.

To clear it, fix the readiness failures listed above it, then re-run
`./setup.sh`. Each run gets a new deployment ID, so it redeploys, re-verifies
and records a fresh `succeeded` annotation. Do not hand-write a succeeded
annotation to silence the check; it is meant to certify a verified release.
`DEPLOYMENT_ANNOTATION_REQUIRED=0 ./check.sh` verifies the signals alone
without the annotation gate.

### Duplicated log lines in Loki

Pods exporting logs over OTLP must carry `observability.mikroways.net/logs: otlp`
so `alloy-logs` skips their stdout. Check with
`kubectl -n demo get pod -l app.kubernetes.io/name=shipping-service -o jsonpath='{.items[0].metadata.annotations}'`.

### Docker Resource Limits

Ensure Docker has enough resources (recommended: 4GB+ RAM, 2+ CPUs).

---

## Cleanup

```bash
kind delete cluster --name grafana-otel-demo
```
