# Beyla eBPF Auto-Instrumentation

Grafana **Beyla** uses eBPF to auto-instrument the Shipping Service without touching application code.

> **Default vs opt-in.** Out of the box the Shipping Service is auto-instrumented
> by the **OpenTelemetry Java agent** (bytecode injection, baked into the image),
> because it works on **any kernel** and makes the demo reliable everywhere.
> **Beyla (eBPF) is a one-flag opt-in** that requires a **BTF-enabled kernel**
> (`CONFIG_DEBUG_INFO_BTF=y`). Both need **zero application code changes** and both
> emit the same `http_server_request_duration_seconds_*` RED metrics, so the
> dashboards work either way. To switch Shipping from the Java agent to Beyla:
>
> ```yaml
> # charts/shipping-service/values.yaml
> instrumentation:
>   javaAgent:
>     enabled: false   # turn the Java agent off...
> beyla:
>   enabled: true      # ...and the eBPF sidecar on (needs a BTF kernel)
> ```
>
> Keep exactly one enabled to avoid double-counting HTTP metrics. The rest of
> this guide is the Beyla deep-dive and a comparison of when to prefer each.

## What is Beyla?

[Beyla](https://github.com/grafana/beyla) is a Grafana tool that uses **eBPF (Extended Berkeley Packet Filter)** to capture application telemetry automatically. No need to:
- Modify source code
- Add SDKs or instrumentation libraries
- Recompile the application

> **Beyla and OpenTelemetry (OBI).** Grafana donated the Beyla core to the
> OpenTelemetry project, where it lives on as **OpenTelemetry eBPF
> Instrumentation (OBI)**. Beyla 3.x — the version pinned in this demo
> (`charts/shipping-service/values.yaml`) — is Grafana's distribution built on
> OBI. This matters for the story this repo tells: even the eBPF
> auto-instrumentation path is an open standard, not a vendor agent.

## How it works

Beyla runs as a **sidecar** alongside the application and uses eBPF to:

1. **Intercept syscalls** from the Linux kernel related to networking
2. **Capture HTTP/gRPC requests** (inbound and outbound)
3. **Generate trace spans** and RED metrics (Rate, Errors, Duration)
4. **Propagate trace context** for distributed tracing

```
┌─────────────────────────────────────────────────────────┐
│                    Kubernetes Pod                        │
│                                                         │
│  ┌──────────────────────┐   ┌─────────────────────────┐ │
│  │  Shipping Service    │   │   Beyla Sidecar         │ │
│  │  (Java Spring Boot)  │   │   (eBPF)                │ │
│  │                      │   │                         │ │
│  │  - No OTEL SDK      │◄──┤  - Captures HTTP/gRPC   │ │
│  │  - Vanilla code      │   │  - Generates traces     │ │
│  │  - Business logic    │   │  - Generates RED metrics│ │
│  │    only              │   │  - Sends OTLP to Alloy  │ │
│  └──────────────────────┘   └─────────────────────────┘ │
│                                        │                │
└────────────────────────────────────────│────────────────┘
                                         │
                                         ▼
                              ┌──────────────────────┐
                              │  Grafana Alloy       │
                              │  (OTLP gateway)      │
                              └──────────────────────┘
```

## Architecture in this project

### Instrumentation comparison

| Service | Language | Instrumentation | Telemetry |
|---------|----------|-----------------|-----------|
| Products Service | Node.js | OTEL SDK (manual) | Traces, Metrics, Logs |
| Orders Service | Python | OTEL SDK (manual) | Traces, Metrics, Logs |
| **Shipping Service** | Java | **OTel Java agent** (default) / **Beyla eBPF** (opt-in) | Traces, RED Metrics |

### Distributed trace flow

```
┌──────────────────┐      ┌──────────────────┐      ┌──────────────────┐
│  Orders Service  │ HTTP │  Shipping Svc    │      │  Grafana Alloy   │
│  (OTEL SDK)      │─────►│  (Beyla eBPF)    │      │  (OTLP gateway)  │
│                  │      │                  │      │                  │
│  span: create    │      │  span: POST      │      │                  │
│    └─ span:      │      │  /api/shipping   │      │                  │
│       request-   │      │  /create         │─────►│  Tempo           │
│       shipping   │      │                  │      │  (Traces)        │
└──────────────────┘      └──────────────────┘      │                  │
                                                    │  Prometheus      │
                                                    │  (Metrics)       │
                                                    └──────────────────┘
```

The trace ID propagates automatically from Orders Service (OTEL SDK) to Shipping Service, where Beyla picks it up and continues the trace.

## Beyla configuration

### Environment variables in the deployment

```yaml
env:
  # Application port to monitor
  - name: BEYLA_OPEN_PORT
    value: "8080"

  # Service name for traces (BEYLA_SERVICE_NAME is deprecated since 2.x;
  # the standard OTEL_SERVICE_NAME is the supported form)
  - name: OTEL_SERVICE_NAME
    value: "shipping-service"

  # Grafana Alloy (OTLP gateway) endpoint
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://alloy.monitoring.svc.cluster.local:4318"

  # OTLP protocol
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: "http/protobuf"
```

### Security requirements

Beyla needs elevated privileges to use eBPF:

```yaml
securityContext:
  privileged: true
  runAsUser: 0
```

It also requires `shareProcessNamespace: true` on the Pod so it can see the application's processes.

## Metrics captured by Beyla

Beyla automatically generates RED metrics:

### Rate (Request rate)
- `http_server_request_duration_seconds_count` - Request counter

### Errors (Error rate)
- Requests with status code >= 400 are counted as errors

### Duration (Latency)
- `http_server_request_duration_seconds` - Latency histogram

### Automatic labels
- `http_request_method` - GET, POST, etc.
- `http_response_status_code` - 200, 404, 500, etc.
- `url_path` - Request path
- `service_name` - Service name

### Matching the HTTP contract (C1)

By default Beyla labels requests with `url_path` (raw path, high cardinality)
and only sets `http_route` when route patterns are configured. The chart
therefore renders a Beyla config file (ConfigMap `<release>-beyla`, mounted at
`/etc/beyla/beyla-config.yml` and loaded via `BEYLA_CONFIG_PATH`) because route
patterns, the unmatched-route mode and histogram buckets have no env var
equivalent in Beyla 3.x:

```yaml
routes:
  patterns:            # taken from ShippingController
    - /api/
    - /api/shipping/quote
    - /api/shipping/create
    - /api/shipping/track/{trackingId}
    - /api/shipping/order/{orderId}
    - /api/slow
    - /api/error
  unmatched: heuristic # anything else is templatized, never exported raw
  ignored_patterns: [/api/health, /health]
otel_metrics_export:
  buckets:
    duration_histogram: [0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 7.5, 10]
```

Result: shipping-service emits a templated `http_route` (e.g.
`/api/shipping/track/{trackingId}`) and no raw-path label, and the duration
histogram includes the 0.25 and 1 boundaries Apdex needs. Metric name, unit
(seconds), `http_request_method` and `http_response_status_code` already match
the Java agent / Node / Python family.

Verification status: configuration only. `helm template` renders the
ConfigMap/volume, and `grafana/beyla:3.24.0` accepts the file at startup, but
the eBPF path could not be exercised without a BTF kernel, so the emitted label
set is not observed end to end. Known remaining differences: no `url_scheme`
label by default and no trace-based exemplars from Beyla (check.sh downgrades
the missing shipping exemplars to a warning when the `beyla` sidecar is present).

### Instrumentation scope name

Beyla 3.x metrics carry `otel_scope_name="go.opentelemetry.io/obi"` (the OBI
meter name; it does **not** contain "beyla"). The Executive dashboard splits
"SDK/agent vs Beyla" on exactly that value.

## Traces captured by Beyla

For each inbound HTTP request, Beyla generates a span with:

- `span.kind`: SERVER
- `http.method`: GET, POST, etc.
- `http.url`: Full URL
- `http.status_code`: Response code
- `http.request.body.size`: Request body size
- `http.response.body.size`: Response body size

## Limitations

1. **No log capture** - Beyla only produces traces and metrics
2. **No business metrics** - Cannot generate custom or business-specific metrics
3. **No manual spans** - You cannot create additional spans inside the code
4. **No custom attributes** - You cannot add custom attributes to spans

## When to use Beyla vs OTEL SDK

| Use case | Beyla | OTEL SDK |
|----------|-------|----------|
| Quick observability without code changes | Yes | No |
| Basic RED metrics | Yes | Yes |
| Custom business metrics | No | Yes |
| Structured logs with trace context | No | Yes |
| Manual spans for internal operations | No | Yes |
| Custom span attributes | No | Yes |
| Legacy apps you cannot modify | Yes | No |
| Fast dev/staging setup | Yes | Yes |

## Verifying Beyla is working

1. **Check Beyla logs**:
```bash
kubectl logs -n demo deployment/shipping-service -c beyla
```

2. **Check metrics**:
```bash
curl http://shipping.127.0.0.1.nip.io/api/health
# Then in Grafana, search for metrics with label service_name="shipping-service"
```

3. **View traces in Tempo**:
- Go to Grafana > Explore > Tempo
- Search for `service.name = "shipping-service"`

## Shipping Service endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/` | GET | Service info |
| `/api/health` | GET | Health check |
| `/api/shipping/quote` | POST | Get shipping quote |
| `/api/shipping/create` | POST | Create shipment |
| `/api/shipping/track/{id}` | GET | Track shipment |
| `/api/shipping/order/{orderId}` | GET | Get shipment by order |
| `/api/slow` | GET | Slow endpoint (for testing) |
| `/api/error` | GET | Error endpoint (for testing) |

## References

- [Beyla GitHub](https://github.com/grafana/beyla)
- [Beyla Documentation](https://grafana.com/docs/beyla/latest/)
- [OpenTelemetry eBPF Instrumentation (OBI)](https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation)
- [eBPF.io](https://ebpf.io/)
