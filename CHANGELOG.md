# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Continuous profiling for the Java shipping-service** via the Pyroscope
  Java agent v2.8.0 (async-profiler), baked into the image and attached as a
  second `-javaagent` through `JAVA_TOOL_OPTIONS` — zero application code
  changes, consistent with the service's instrumentation story. Pushes JFR
  profiles (CPU via itimer + allocation + lock) directly to Pyroscope with
  the same `service_name`/`service_namespace` identity as the other signals.
  Enabled by default (`profiling.pyroscope.enabled`), independent of the
  OTel-agent-vs-Beyla choice. The Continuous Profiling dashboard now shows
  Node.js and Java flame graphs side by side, and `check.sh` verifies
  shipping-service profiles too.
- **CI pipeline on GitHub Actions** (`.github/workflows/ci.yaml`): shellcheck
  on every script, `helm lint` + `kubeconform -strict` per chart, `promtool
  check rules` on the SLO recording rules extracted from
  `kind/values/prometheus.yaml`, JSON validation of all 17 dashboard
  ConfigMaps, Docker builds of the 4 demo services, and a report-only Trivy
  config scan.
- **E2E workflow** (`.github/workflows/e2e.yaml`, manual + weekly): boots the
  full demo on a runner via `setup.sh` and gates on `check.sh` (4 signals).

### Fixed
- `traffic.sh`: declare-and-assign split on 6 `local` statements (shellcheck
  SC2155 — masked command exit codes).

### Changed
- **Deployment identity is now unique-by-default and end-to-end**: each `setup.sh` run
  uses one release tag across container images, Kubernetes Deployment/Pod
  labels, OpenTelemetry `service.version` / `deployment.environment.name` and
  Faro app metadata. Reusing a Kind cluster now performs a real rollout instead
  of silently keeping an old `latest` pod.
- `incident.sh` no longer invents deploy/rollback events. It records incident
  simulations and recovery separately and closes the region at the actual end.
- Deployment, incident and recovery annotations are separate, color-coded and
  available on all provisioned dashboards.
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
- `deployment-snapshot.sh`: atomic, no-overwrite `deployment-snapshot.v1`
  evidence bundles containing the deployment event, Kubernetes/Helm state,
  image IDs, matching Grafana annotation/dashboard/alerts, six post-deploy SLIs
  and verified SHA-256 checksums. `setup.sh` captures one after every certified
  successful release.
- `deploy-observe.sh`: reusable local/CI deployment annotation client with
  success/failure, actual duration, services, version, environment, revision,
  actor, pipeline URL and optional `deployment-event.v1` JSON artifact.
- **Deployment Health** dashboard: release identity, rollout convergence,
  image digests/restarts and current-versus-historical-offset throughput, error rate,
  P95, Apdex and synthetic availability.
- `docs/DEPLOYMENT_OBSERVABILITY.md` with the CI/CD contract, authentication,
  audit-boundary and cardinality guidance.
- Renovate configuration (`renovate.json`) covering Helm charts (helmfile),
  container images, npm/Maven/pip dependencies and pinned versions annotated
  with `# renovate:` markers (OTel Java agent, Faro bundles, Beyla, Grafana
  image, kind node image, k6 image).
- `CONTRIBUTING.md`, `SECURITY.md` and this `CHANGELOG.md`.
- README badges and a versioned Mermaid architecture diagram.

### Fixed
- `check.sh` now rejects `1/2 Running` pods, verifies release labels on
  Deployment/Pod pairs and requires a real deployment annotation. `setup.sh`
  fails closed when readiness validation fails.
- Canonical SLO error-ratio rules now include both SDK and Java-agent services
  and no longer dilute low-volume traffic with `clamp_min(rate, 1)`. Grafana
  error/P95 alerts reuse canonical populations and cover Shipping.
- Alloy pod-log labels now use canonical service name, release version and
  deployment environment, matching OTLP telemetry.
- Documentation drift left over from the Alloy consolidation: README
  component list (Alloy, Pyroscope, blackbox exporter were missing/wrong),
  `kind/README.md` structure, `docs/TROUBLESHOOTING.md` and
  `docs/VERIFICATION_CHECKLIST.md` commands (the standalone OTel Collector no
  longer exists; `quick-traffic.sh` never shipped), `docs/BEYLA.md` diagrams
  and env vars, `docs/PRODUCTION.md` NetworkPolicy/scaling examples,
  shipping-service `/api/` info payload and code comments, `setup.sh` and
  `incident.sh` messages that still claimed Beyla was the default
  instrumentation for the Java service.
- **Cost figures are now internally consistent** across `README.md`,
  `FOR_CTOS.md` and `docs/COST_ANALYSIS.md`: one reference scenario (50 hosts,
  100 GB logs/month, 10-12 platform users), vendor totals that match their own
  component breakdowns (New Relic now includes user seats — the dominant cost
  its per-GB tables omitted; Datadog list price vs typical billed amounts is
  explicit), a self-hosted TCO with the labor assumption out in the open
  (existing platform team vs dedicated hire, production-grade HA
  infrastructure instead of the single-node minimum) and a break-even
  calculation for both scenarios. The three-year self-hosted total previously
  appeared as both $55,000 and $110,000 in the same document.
- "Unlimited retention" claims replaced with storage-bound retention and a
  note about what the demo actually configures (15-day metrics, ephemeral
  traces/profiles) in `README.md`, `DEMO.md` and `docs/COST_ANALYSIS.md`.
- `docs/API.md` no longer claims Beyla eBPF is the Shipping service's
  telemetry source; the OTel Java agent is the default and Beyla stays
  opt-in. The historical banner in `docs/IMPROVEMENTS.md` now maps the
  renamed traffic script (`generate-traffic.sh` → `traffic.sh`).

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
