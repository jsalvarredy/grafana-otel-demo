# CLAUDE.md - Contexto del proyecto para Claude Code

## Proyecto
Prueba de concepto de observabilidad on-premise con Grafana Stack + OpenTelemetry.
Demuestra alternativa open-source a Datadog/NewRelic: cuatro señales (métricas,
logs, trazas, perfiles) correlacionadas entre sí, RUM, synthetic monitoring,
SLOs multi-burn-rate y exploración queryless (Drilldown).
**Owner**: Mikroways (jsalvarredy)

## Stack tecnológico
- **Orquestación**: Kind (Kubernetes 1.33.4, single node)
- **Métricas**: Prometheus (chart prometheus-community, remote-write receiver + exemplars)
- **Logs**: Loki (SingleBinary + Memcached)
- **Trazas**: Tempo 2.8 (filesystem local, metrics-generator activo: span metrics + service graph)
- **Perfiles**: Pyroscope (continuous profiling, flame graphs)
- **Visualización**: Grafana 13 (imagen pineada sobre el chart; admin/Mikroways123)
- **Pipeline de telemetría**: Grafana Alloy en dos releases:
  - `alloy` (Deployment): faro.receiver (RUM) + gateway OTLP con
    memory_limiter → k8sattributes → tail_sampling → batch → Tempo/Prometheus(remote_write con exemplars)/Loki.
    Una sola réplica a propósito: tail sampling necesita todos los spans de una traza en un proceso.
  - `alloy-logs` (DaemonSet): tail de stdout de todos los pods → Loki
    (reemplazó a Promtail/Grafana Agent, ambos EOL)
- **Synthetic monitoring**: prometheus-blackbox-exporter (job blackbox-http)
- **Load testing**: Grafana k6 (Job in-cluster, remote write a Prometheus)

## Microservicios demo
| Servicio | Lenguaje | Instrumentación | Ingress |
|----------|----------|-----------------|---------|
| Products Service | Node.js 22 (Express) | OTel SDK 2.x manual + Pyroscope | products.127.0.0.1.nip.io |
| Orders Service | Python 3.13 (Flask) | OTel SDK manual | orders.127.0.0.1.nip.io |
| Shipping Service | Java 21 (Spring Boot 3.5) | OTel Java agent (default) / Beyla eBPF 3.x (opt-in, requiere kernel BTF) + Pyroscope Java agent (profiling) | shipping.127.0.0.1.nip.io |
| Faro Shop (frontend) | nginx + Faro Web SDK (vendored) | Grafana Faro (RUM) + web tracing browser→backend | shop.127.0.0.1.nip.io |

## Estructura del repo
```
charts/                    # Helm charts: otel-demo-app, otel-python-app, shipping-service, frontend-app
kind/
  .kind/config.yaml        # Kind cluster config (puertos 80/443 mapeados)
  helmfile.d/              # Un helmfile con todos los releases (ingress, LGTM+P, alloy x2, blackbox)
  values/                  # Values por release (alloy, alloy-logs, prometheus, loki, tempo, grafana, pyroscope, blackbox-exporter)
  dashboards/              # 16 ConfigMaps con dashboards Grafana
src/
  otel-app/                # Products (Node): index.js + tracing.js (SDK OTel 2.x)
  otel-python-app/         # Orders (Python): app.py
  shipping-service/        # Shipping (Java, SIN código OTel; agent baked-in en la imagen)
  frontend-app/            # Dockerfile nginx + bundles Faro vendored (pineados por ARG)
docs/                      # API, BEYLA, TROUBLESHOOTING, PRODUCTION, COST_ANALYSIS, IMPROVEMENTS (histórico), VERIFICATION_CHECKLIST
setup.sh                   # Setup completo: cluster + helmfile + dashboards + apps + tráfico + check
traffic.sh                 # Generador de tráfico continuo
incident.sh                # Inyector de incidentes para demos en vivo (errores/latencia + anotaciones)
check.sh                   # Readiness check: 4 señales + service map + exemplars + plugins + alertas
k6.sh / k6/load.js         # Load test k6 in-cluster con remote write a Prometheus
DEMO.md                    # Guion de demo de 12 minutos
FOR_CTOS.md                # Brief para líderes de ingeniería (costos y trade-offs)
```

## Métricas clave en Prometheus
- **HTTP (all 3 apps)**: `http_server_request_duration_seconds_count` / `_bucket` / `_sum` (stable semconv, seconds; labels `http_request_method`, `http_response_status_code`, `http_route` (template), `url_scheme`, `service_name`). Products/Orders emit it through the official library instrumentation (`instrumentation-http` + express / `instrumentation-flask`) with `OTEL_SEMCONV_STABILITY_OPT_IN=http`; buckets are pinned by a View in Node. `http_requests_total` and `http_server_duration_milliseconds*` no longer exist.
- **Span metrics (Tempo generator)**: `traces_spanmetrics_*` (label `service`, dimensión `db.system`), `traces_service_graph_*`
- **Recording rules**: `job:http_errors:*`, `service:http_errors:*` (SLO burn rates, budget 0.001 = SLO 99.9%), `service:apdex:ratio5m` (Apdex T=250ms)
- **Business**: revenue_at_risk_dollars, transaction_value_dollars, customer_experience_score, orders_created_total
- **Synthetic**: probe_success, probe_duration_seconds (blackbox)
- **k6**: k6_* vía remote write

## 17 dashboards provisionados
Platform Home (landing por defecto), APM (Apdex), Service Time Breakdown,
Service Overview (RED), Service Map, Distributed Tracing, Continuous Profiling,
Logs Search, Log Analysis, Executive, Observability Overview, SLO/SLI Error
Budget, Synthetic Monitoring, Frontend/RUM, k6 Load Testing, K8s Cluster.
Alertas provisionadas en Grafana (no Alertmanager): error rate, P95, SLO
fast/slow burn (multi-window), service down, synthetic probe down.

## Decisiones técnicas que hay que conocer
- Las queries de dashboards/reglas unen DOS familias de métricas HTTP con `or`:
  la legacy de los SDK apps (`http_server_duration_milliseconds*`, ms) y la
  semconv estable del Java agent (`http_server_request_duration_seconds*`).
  Los matchers `le=~"250(\.0+)?"` aceptan ambos formatos de bucket.
- Exemplars: Python emits them on `http.server.request.duration` with
  `OTEL_METRICS_EXEMPLAR_FILTER=trace_based` (verified in the OTLP data point);
  Node cannot (see known issues). Alloy's remote write uses
  `send_exemplars: true`; Prometheus runs with `enable-feature=exemplar-storage`.
- Tempo: `overrides.defaults.metrics_generator.processors` habilita
  service-graphs, span-metrics y local-blocks. En Tempo 2.8
  `overrides.defaults.search` NO existe (error "field defaults not found").
- Tempo crashloop conocido: demasiadas queries TraceQL concurrentes saturan
  CPU/RAM → mitigado en values (max_concurrent_queries 10, límites de search,
  probes tolerantes). Si reaparece, revisar kind/values/tempo.yaml.
- Grafana: los Drilldown apps se instalan con un init container (grafana cli);
  necesitan egress a grafana.com en el arranque del pod.
- Beyla es opt-in (`beyla.enabled=true` + `instrumentation.javaAgent.enabled=false`);
  exactamente UNO de los dos debe estar activo para no duplicar métricas.
  Beyla 3.x = distro Grafana de OpenTelemetry eBPF Instrumentation (OBI);
  `BEYLA_SERVICE_NAME` está deprecado, se usa `OTEL_SERVICE_NAME`.

## Problemas conocidos
- Beyla sidecar requiere `privileged: true` y kernel con BTF (CONFIG_DEBUG_INFO_BTF=y)
- Loki gateway da 502 transitorio durante startup (se resuelve solo con retry)
- Los logs del shipping-service llegan a Loki DUPLICADOS (verificado 2026-07):
  una vez por el DaemonSet de stdout (sin trace_id) y otra por OTLP del Java
  agent (CON trace_id/span_id). La correlación trace→log de Java funciona por
  la vía OTLP; falta decidir/filtrar una de las dos vías (Bloque C del informe)
- Node exemplars: `@opentelemetry/sdk-metrics` 2.12.0 ships the exemplar classes
  but does not export them, MeterProvider/View have no option to select a
  filter or reservoir, and the aggregators never use them, so
  `OTEL_METRICS_EXEMPLAR_FILTER` is a no-op. Products' metric -> trace jump relies
  on Tempo's span metrics.
- Python usa `opentelemetry._logs` (la API de logs de OTel Python sigue siendo experimental)

## Mejoras pendientes priorizadas (auditoría 2026-07)
- ~~CI en GitHub Actions~~ HECHO: `.github/workflows/ci.yaml` (shellcheck,
  helm lint + kubeconform, promtool, JSON de dashboards, builds, Trivy
  report-only) + `e2e.yaml` (kind + setup.sh + check.sh, manual/semanal).
  Pendiente: promover e2e a gate de PR cuando acumule historial estable.
- GIF del flujo exemplar→trace→log→flame graph y devcontainer/Codespaces en README
- PostgreSQL real para reemplazar los spans simulados de DB (withPostgres/withRedis/withMongo)
- Profiling para Python (Node y Java ya empujan a Pyroscope; Java vía
  agente Pyroscope baked-in, segundo -javaagent en JAVA_TOOL_OPTIONS)
- Retention en Loki + persistencia para Tempo/Pyroscope
- NetworkPolicies, securityContext en shipping/frontend, ServiceAccounts dedicados
- Folders para los 17 dashboards; reemplazar el K8s dashboard genérico (212KB importado)
- UI de Alloy expuesta por ingress (grafo del pipeline en vivo) y dashboard de meta-monitoring

## Comandos útiles
```bash
export KUBECONFIG="$PWD/kind/.kube/config"
./setup.sh                              # Setup completo desde cero
./check.sh                              # Verificar que la demo está lista (4 señales)
./traffic.sh --continuous --fast        # Tráfico continuo
./incident.sh -s meltdown -d 600        # Incidente en vivo (errores+latencia)
./incident.sh --recover                 # Recuperación
./k6.sh --vus 20 --hold 5m              # Load test k6
helmfile -f kind/helmfile.d/ apply      # Re-aplicar solo infra
kubectl apply -f kind/dashboards/       # Re-aplicar dashboards
kind delete cluster --name grafana-otel-demo  # Cleanup
```
