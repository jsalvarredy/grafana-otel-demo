# CLAUDE.md - Contexto del proyecto para Claude Code

## Proyecto
Prueba de concepto de observabilidad on-premise con Grafana Stack + OpenTelemetry.
Demuestra alternativa open-source a Datadog/NewRelic.
**Owner**: Mikroways (jsalvarredy)

## Stack tecnologico
- **Orquestacion**: Kind (Kubernetes 1.33.4, single node)
- **Metricas**: Prometheus 25.11.0
- **Logs**: Loki 6.6.6 (SingleBinary + Memcached)
- **Traces**: Tempo 2.8.0 (local filesystem)
- **Visualizacion**: Grafana (latest, admin/Mikroways123)
- **Collector**: OpenTelemetry Collector Contrib (v0.145.0)
- **Auto-instrumentacion**: Beyla eBPF 1.8.4

## Microservicios demo
| Servicio | Lenguaje | Instrumentacion | Ingress |
|----------|----------|-----------------|---------|
| Products Service | Node.js 18 (Express) | OTel SDK manual | products.127.0.0.1.nip.io |
| Orders Service | Python 3.11 (Flask) | OTel SDK manual | orders.127.0.0.1.nip.io |
| Shipping Service | Java 17 (Spring Boot 3.2) | Beyla eBPF sidecar | shipping.127.0.0.1.nip.io |

## Estructura del repo
```
charts/                    # Helm charts para las 3 apps (otel-demo-app, otel-python-app, shipping-service)
kind/
  .kind/config.yaml        # Kind cluster config
  helmfile.d/              # Helmfile con todos los releases (ingress, prometheus, loki, tempo, grafana, otel-collector)
  values/                  # Helm values (prometheus.yaml, loki.yaml, tempo.yaml, grafana.yaml, otel-collector.yaml)
  dashboards/              # 8 ConfigMaps con dashboards Grafana
src/
  otel-app/                # Products Service (index.js + tracing.js)
  otel-python-app/         # Orders Service (app.py)
  shipping-service/        # Shipping Service (Java, SIN OTel SDK)
docs/                      # API.md, BEYLA.md, TROUBLESHOOTING.md, PRODUCTION.md, COST_ANALYSIS.md, etc.
setup.sh                   # Script principal: crea cluster, despliega todo, genera trafico
traffic.sh                 # Generador de trafico continuo
```

## Metricas clave disponibles en Prometheus
- **SDK services**: `http_requests_total` (labels: status_code, method, endpoint, service_name)
- **SDK histogram**: `http_server_duration_milliseconds_bucket` (latencia)
- **Beyla**: `http_server_request_duration_seconds_count` / `_bucket` (labels: http_response_status_code, service_name)
- **Business**: revenue_at_risk_dollars, transaction_value_dollars, customer_experience_score, orders_created_total
- **Infra**: cache_hits_total, rate_limited_requests_total, circuit_breaker_state

## 8 Dashboards provisionados
1. K8S Dashboard
2. Logs Search
3. Service Overview (RED metrics)
4. Distributed Tracing
5. Log Analysis
6. Executive Dashboard
7. Observability Platform Overview
8. SLO / SLI - Error Budget (uid: slo-sli-error-budget-v1)

## Cambios realizados en la sesion del 2025-02-10

### Auditoria con 4 skills (devops-engineer, kubernetes-specialist, opentelemetry, grafana-dashboards)

**otel-collector.yaml** - Agregado memory_limiter processor (400MiB limit, 100MiB spike), health_check extension (puerto 13133), batch config explicito (1024 batch size, 5s timeout), resource limits (500m/512Mi). Pipeline order: memory_limiter -> k8sattributes -> batch.

**Deployments de Products y Orders** - Agregados liveness/readiness probes (GET /health), pod securityContext (runAsNonRoot, UID 1001), container securityContext (allowPrivilegeEscalation: false, drop ALL capabilities).

**prometheus.yaml** - Agregados resource limits (500m CPU, 512Mi RAM).

**grafana.yaml** - Agregado tracesToMetrics y serviceMap en Tempo datasource para correlacion completa entre los 3 pilares.

**README.md** - Actualizado conteo de dashboards a 8.

### Dashboard SLO/SLI creado (slo-sli-dashboard.yaml)
18 paneles: Availability SLI, Error Budget Remaining, Burn Rate, Throughput, timeseries de availability y burn rate con threshold lines, per-service availability y error rate (queries separadas para SDK vs Beyla), P95/P99 latency, request rate stacked, 5xx errors. Variable interactiva: slo_target (99.9%, 99.5%, 99%, 95%).

### Fix Tempo crashloop (problema recurrente)
**Causa raiz**: Tracing dashboard dispara ~18 queries TraceQL concurrentes. Saturan CPU/RAM de Tempo, no responde a liveness probe, Kubernetes lo mata.
**Solucion en tempo.yaml**:
- Recursos: 250m/512Mi requests, 1 CPU/2Gi limits (era 100m/256Mi, 1/1Gi)
- querier.max_concurrent_queries: 10
- queryFrontend.search: max_result_limit 50, max_duration 1h
- server timeouts: 60s read/write
- Probes: timeoutSeconds 10 (era 5), failureThreshold 5 (era 3), liveness periodSeconds 15 (era 10)
- NOTA: overrides.defaults.search no funciona en Tempo 2.8.0 (da error "field defaults not found in type overrides.legacyConfig")

## Problemas conocidos
- Beyla sidecar requiere `privileged: true` (necesario para eBPF)
- Loki gateway da 502 transitorio durante startup (se resuelve solo con retry del collector)
- Prometheus exporter del collector genera warnings "Instrument description conflict" (informativo, no afecta funcionalidad)
- `SemanticResourceAttributes` en tracing.js de Node.js esta deprecated (migrar a ATTR_SERVICE_NAME)
- Python usa `opentelemetry._logs` que es API privada

## Mejoras pendientes sugeridas
- GitHub Actions CI (lint Helm charts, build images, Trivy scan)
- NetworkPolicies (demo ns solo habla con monitoring ns)
- ServiceAccounts dedicados para pods de app
- Tail sampling en el Collector (100% errores, samplear trafico normal)
- Template variables (service selector) en service-overview dashboard

## Comandos utiles
```bash
export KUBECONFIG="$PWD/kind/.kube/config"
./setup.sh                              # Setup completo desde cero
./traffic.sh --continuous               # Trafico continuo
kind delete cluster --name grafana-otel-demo  # Cleanup
helmfile -f kind/helmfile.d/ apply      # Re-aplicar solo infra
kubectl get pods -A                     # Ver todos los pods
```
