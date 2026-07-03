# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Runtimes off EOL**: Products service moved from Node.js 18 (EOL) to
  Node.js 22 LTS; Orders service base image from Python 3.11 to 3.13;
  Shipping service from Spring Boot 3.2 / Java 17 to Spring Boot 3.5.3 /
  Java 21.
- **OpenTelemetry JS SDK migrated from 0.45.x to the 2.x line** (SDK 0.220 /
  stable packages 2.9): `resourceFromAttributes` replaces `new Resource()`,
  the NodeSDK now owns the logger provider (`logRecordProcessors` /
  `metricReaders`), single shutdown path for all three signals.
- **Grafana Faro Web SDK bumped 1.19.0 → 2.8.2** (vendored bundles pinned via
  build ARG; same IIFE globals and API).
- **Beyla bumped 1.8.4 → 3.24.0** — Beyla 3.x is Grafana's distribution of
  OpenTelemetry eBPF Instrumentation (OBI), the Beyla core donated to the
  OpenTelemetry project. `BEYLA_SERVICE_NAME` (deprecated) replaced by
  `OTEL_SERVICE_NAME` in the opt-in sidecar. Still opt-in, still requires a
  BTF-enabled kernel.
- Express bumped to 4.22.x.

### Added
- Renovate configuration (`renovate.json`) covering Helm charts (helmfile),
  container images, npm/Maven/pip dependencies and pinned versions annotated
  with `# renovate:` markers (OTel Java agent, Faro bundles, Beyla, Grafana
  image, kind node image, k6 image).
- `CONTRIBUTING.md`, `SECURITY.md` and this `CHANGELOG.md`.
- README badges and a versioned Mermaid architecture diagram.

### Fixed
- Documentation drift left over from the Alloy consolidation: README
  component list (Alloy, Pyroscope, blackbox exporter were missing/wrong),
  `kind/README.md` structure, `docs/TROUBLESHOOTING.md` and
  `docs/VERIFICATION_CHECKLIST.md` commands (the standalone OTel Collector no
  longer exists; `quick-traffic.sh` never shipped), `docs/BEYLA.md` diagrams
  and env vars, `docs/PRODUCTION.md` NetworkPolicy/scaling examples,
  shipping-service `/api/` info payload and code comments, `setup.sh` and
  `incident.sh` messages that still claimed Beyla was the default
  instrumentation for the Java service.

### Removed
- `docs/Architecture.jpg` (pre-Alloy architecture; replaced by the Mermaid
  diagram in the README, which is versioned with the code).

## [1.0.0] - 2026-07-02

Baseline of the proof of concept as demoed:

- Kind-based stack: Grafana 13, Prometheus, Loki, Tempo, Pyroscope,
  blackbox exporter, and Grafana Alloy (OTLP/Faro gateway Deployment +
  node-log DaemonSet).
- Four correlated signals (metrics ↔ traces ↔ logs ↔ profiles) with
  exemplars, tail sampling, span metrics and service graph.
- Three instrumented microservices (Node.js, Python, Java zero-code via the
  OTel Java agent, Beyla eBPF opt-in) plus the Faro Shop frontend (RUM +
  browser→backend tracing).
- 16 provisioned dashboards, provisioned Grafana alerts including
  multi-window multi-burn-rate SLO alerts, synthetic monitoring, k6 load
  testing, incident injector and demo readiness check.
