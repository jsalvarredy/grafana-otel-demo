# Beyla eBPF Auto-Instrumentation

This document explains how Grafana's **Beyla** auto-instruments the Shipping Service without touching application code.

## What is Beyla?

[Beyla](https://github.com/grafana/beyla) is a Grafana tool that uses **eBPF (Extended Berkeley Packet Filter)** to capture application telemetry automatically. No need to:
- Modify source code
- Add SDKs or instrumentation libraries
- Recompile the application

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
│  │    only              │   │  - Sends to OTEL Col.   │ │
│  └──────────────────────┘   └─────────────────────────┘ │
│                                        │                │
└────────────────────────────────────────│────────────────┘
                                         │
                                         ▼
                              ┌──────────────────────┐
                              │  OTEL Collector      │
                              │  (traces & metrics)  │
                              └──────────────────────┘
```

## Architecture in this project

### Instrumentation comparison

| Service | Language | Instrumentation | Telemetry |
|---------|----------|-----------------|-----------|
| Products Service | Node.js | OTEL SDK (manual) | Traces, Metrics, Logs |
| Orders Service | Python | OTEL SDK (manual) | Traces, Metrics, Logs |
| **Shipping Service** | Java | **Beyla eBPF** | Traces, RED Metrics |

### Distributed trace flow

```
┌──────────────────┐      ┌──────────────────┐      ┌──────────────────┐
│  Orders Service  │ HTTP │  Shipping Svc    │      │  OTEL Collector  │
│  (OTEL SDK)      │─────►│  (Beyla eBPF)    │      │                  │
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

  # Service name for traces
  - name: BEYLA_SERVICE_NAME
    value: "shipping-service"

  # OTEL Collector endpoint
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-collector:4318"

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
- [eBPF.io](https://ebpf.io/)
