# Production Deployment Guide

This demo runs on Kind for local evaluation. Production deployments require additional considerations.

## What This Demo Does NOT Include

| Component | Demo | Production Requirement |
|-----------|------|----------------------|
| Kubernetes | Kind (local) | Managed K8s (EKS, GKE, AKS) or self-managed |
| Storage | Ephemeral | Persistent volumes with backup |
| High Availability | Single replicas | Multiple replicas across zones |
| TLS | None | TLS everywhere |
| Authentication | Basic auth | SSO/OIDC integration |
| Network | Host access | Proper ingress, firewall rules |
| Secrets | Plain ConfigMaps | External secrets management |

---

## Infrastructure Requirements

### Kubernetes Cluster

- **Nodes**: Minimum 3 nodes for HA
- **Resources per node**: 4 vCPU, 16GB RAM (minimum for small deployments)
- **Storage class**: Fast SSD-backed storage for Tempo and Loki

### Storage Sizing (Starting Point)

| Component | Storage | Notes |
|-----------|---------|-------|
| Prometheus | 100GB | 15-day retention typical |
| Loki | 500GB+ | Depends on log volume |
| Tempo | 200GB+ | Depends on trace volume |
| Grafana | 10GB | Dashboards and config |

### Network Requirements

- Ingress controller with TLS termination
- Internal service mesh (optional but recommended)
- Egress rules for any external integrations

---

## High Availability Configuration

### Grafana

```yaml
replicas: 2
persistence:
  enabled: true
  size: 10Gi
database:
  type: postgres  # External PostgreSQL for HA
```

### Loki

Use distributed mode for production:

```yaml
loki:
  deploymentMode: distributed
  ingester:
    replicas: 3
  distributor:
    replicas: 2
  querier:
    replicas: 2
```

### Tempo

```yaml
tempo:
  replicas: 3
  storage:
    trace:
      backend: s3  # Or GCS, Azure Blob
```

### Prometheus

Consider Thanos or Cortex for long-term storage and HA:

```yaml
prometheus:
  replicas: 2
thanosRuler:
  enabled: true
```

---

## Security Hardening

### TLS Configuration

1. Use cert-manager for certificate management
2. Enable TLS between all components
3. Use TLS for OTLP ingestion

### Authentication

1. Configure OIDC for Grafana
2. Use mTLS for service-to-service communication
3. Implement RBAC for Kubernetes resources

### Network Policies

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: otel-collector-ingress
spec:
  podSelector:
    matchLabels:
      app: otel-collector
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: demo
      ports:
        - port: 4317
        - port: 4318
```

---

## Scaling Guidelines

### OpenTelemetry Collector

| Throughput | Replicas | CPU | Memory |
|------------|----------|-----|--------|
| <10k spans/s | 2 | 500m | 512Mi |
| 10k-50k spans/s | 3-5 | 1 | 1Gi |
| >50k spans/s | 5+ | 2 | 2Gi |

### Loki Ingester

| Log Volume | Replicas | CPU | Memory |
|------------|----------|-----|--------|
| <100GB/day | 3 | 1 | 2Gi |
| 100-500GB/day | 5-10 | 2 | 4Gi |
| >500GB/day | 10+ | 4 | 8Gi |

---

## Backup and Disaster Recovery

### What to Backup

1. **Grafana**: Dashboards, data sources, alerts (export JSON)
2. **Prometheus rules**: AlertManager config, recording rules
3. **Loki/Tempo data**: Object storage replication
4. **Kubernetes manifests**: GitOps repository

### Backup Strategy

```bash
# Export Grafana dashboards
for dashboard in $(curl -s http://grafana/api/search | jq -r '.[].uid'); do
  curl -s "http://grafana/api/dashboards/uid/$dashboard" > "backup/$dashboard.json"
done
```

---

## Monitoring the Monitoring Stack

Yes, you need to monitor your monitoring infrastructure:

1. **Alertmanager** for critical alerts
2. **Uptime checks** for Grafana endpoint
3. **Prometheus self-monitoring** metrics
4. **Loki/Tempo health endpoints**

Key metrics to watch:
- `prometheus_tsdb_head_samples_appended_total`
- `loki_ingester_chunks_flushed_total`
- `tempo_ingester_traces_created_total`

---

## Migration Path from Demo

1. **Export dashboards** from demo Grafana
2. **Document custom instrumentation** in your services
3. **Plan storage backend** (S3, GCS, etc.)
4. **Set up CI/CD** for Helm deployments
5. **Configure alerting rules**



