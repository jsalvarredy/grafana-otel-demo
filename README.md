# Grafana LGTP + OpenTelemetry Demo

> **⚠️ DEMO ENVIRONMENT** - This repository demonstrates a complete observability stack using the **Grafana LGTPStack** (Loki, Grafana, Tempo, Prometheus) and **OpenTelemetry** in a local Kubernetes environment.

[![OpenTelemetry](https://img.shields.io/badge/OpenTelemetry-Instrumented-blue?logo=opentelemetry)](https://opentelemetry.io/)
[![Grafana](https://img.shields.io/badge/Grafana-Stack-orange?logo=grafana)](https://grafana.com/)
[![Kind](https://img.shields.io/badge/Kubernetes-Kind-326CE5?logo=kubernetes)](https://kind.sigs.k8s.io/)

A complete, ready-to-run demonstration of modern observability. This demo showcases the collection and visualization of **traces**, **metrics**, and **logs** from sample applications in both **Node.js** and **Python**, demonstrating OpenTelemetry's language-agnostic capabilities seamlessly integrated with the Grafana ecosystem.

## 🎯 What This Demo Shows

This repository demonstrates a **production-grade observability setup** that you can run locally in minutes:

- **🌐 Multi-Language Support**: See OpenTelemetry work seamlessly across Node.js and Python
- **📊 Grafana LGTP Stack**:
    - **Loki**: Logs aggregation
    - **Grafana**: Visualization and Dashboards
    - **Tempo**: Distributed Tracing
    - **Prometheus**: Metrics Storage
- **🔍 Distributed Tracing**: Visualize request flows
- **📈 Custom Metrics**: Track business and technical KPIs
- **📝 Structured Logging**: JSON logs
- **🔄 Full Integration**: See how traces, metrics, and logs work together in Grafana

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────┐
│              Kind Kubernetes Cluster                 │
├─────────────────────────────────────────────────────┤
│                                                      │
│  ┌──────────────┐         ┌──────────────┐         │
│  │    Nginx     │◄────────┤   Ingress    │         │
│  │   Ingress    │  :80    │   Resources  │         │
│  └──────┬───────┘         └──────────────┘         │
│         │                                           │
│    ┌────┴──────┬──────────────┬─────────────┐      │
│    │           │              │             │      │
│  ┌─▼────────┐ ┌▼───────────┐ ┌▼───────────┐ │      │
│  │ Grafana  │ │ Node.js    │ │  Python    │ │      │
│  │  LGTM    │ │  Demo      │ │   Demo     │ │      │
│  │          │ │            │ │            │ │      │
│  │  • Loki  │ │            │ │            │ │      │
│  │  • Tempo │◄─┤ OTEL SDK   │◄─┤ OTEL SDK   │ │     │
│  │  • Prometheus │ │  • Traces  │ │  • Traces  │ │      │
│  │  • Graf  │ │  • Metrics │ │  • Metrics │ │      │
│  │  ana     │ │  • Logs    │ │  • Logs    │ │      │
│  │          │ │            │ │            │ │      │
│  └──────────┘ └────────────┘ └────────────┘ │      │
│                                              │      │
│        grafana.localhost     otel-example      │      │
│                            .localhost         │      │
│                                               │      │
│                              python-otel-example     │
│                              .localhost              │
53: └─────────────────────────────────────────────────────┘
```

## ⚡ Quick Start

### Prerequisites

Ensure you have these tools installed:
- **Docker** (≥20.10)
- **Kind** (≥0.20)
- **Kubectl** (≥1.28)
- **Helm** (≥3.12)

### One-Command Setup

```bash
./setup.sh
```

**Setup time**: ~5-10 minutes.

The script will:
1. ✅ Create a Kind cluster
2. ✅ Deploy Grafana, Loki, Tempo, Prometheus
3. ✅ Deploy OpenTelemetry Collector
4. ✅ Build and deploy the instrumented demo apps

### Configure DNS Resolution

Add these entries to your `/etc/hosts` file:

```bash
127.0.0.1 grafana-otel-demo.localhost otel-example.localhost python-otel-example.localhost
```

### Access the Platform

**Grafana UI**: [http://grafana-otel-demo.localhost](http://grafana-otel-demo.localhost)
```
User:     admin
Password: Mikroways123
```

**Demo Applications**:
- Node.js: [http://otel-example.localhost](http://otel-example.localhost)
- Python: [http://python-otel-example.localhost](http://python-otel-example.localhost)

## 🧪 Exploring the Demo

### Generate Traffic

The setup script runs a traffic generator initially, but you can generate more:

```bash
# Node.js app
curl http://otel-example.localhost/rolldice
curl http://otel-example.localhost/work

# Python app
curl http://python-otel-example.localhost/rolldice
```

### What to Explore in Grafana

1.  **Explore Data**:
    *   Click "Explore" in the Grafana sidebar.
    *   **Logs**: Select **Loki** datasource. Query standard logs.
    *   **Traces**: Select **Tempo** datasource. Search for traces.
    *   **Metrics**: Select **Prometheus** datasource. Query `http_requests_total`.

2.  **Dashboards**:
    *   Go to Dashboards > Browse.
    *   Look for the OpenTelemetry Demo dashboard (if provisioned) or create a new one using the datasources.

## 🔧 Technical Details

### OpenTelemetry Instrumentation

The applications send telemetry to a centralized **OpenTelemetry Collector** running in the cluster (`otel-collector-opentelemetry-collector`).

*   **Traces** -> Forwarded to **Tempo** (gRPC)
*   **Metrics** -> Forwarded to **Prometheus** (Prometheus Remote Write)
*   **Logs** -> Forwarded to **Loki** (OTLP/HTTP)

## 🧹 Cleanup

To completely remove the demo environment:

```bash
kind delete cluster --name grafana-otel-demo
```

---

**Built for demonstration and learning**  
Questions? Open an issue or check the troubleshooting section above.
