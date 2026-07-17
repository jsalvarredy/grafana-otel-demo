# Demo Script — The Power of Grafana Observability

A ~12 minute guided walkthrough that turns this stack into a *story*. The arc:
**everything is green → explore without queries → something breaks → follow the
signal from a metric to the exact trace, log and flame graph → the alert fires
and the error budget burns → recovery.**

It is built so anyone can deliver the demo, even without knowing PromQL/LogQL/TraceQL.

---

## 0. Before you present (5 min prep)

**Bring the stack up** (first run takes 8–12 min):

```bash
./setup.sh
```

**Confirm it's demo-ready** — a green/red check across the four signals, the
service map, exemplars, the Drilldown plugins and the alert state:

```bash
./check.sh
```

It prints **✓ READY TO DEMO** once metrics, logs, traces, profiles, the service
map and alerting are all wired (`setup.sh` runs it for you at the end). Run it
again any time before you present.

**Access**

| What | URL | Login |
|------|-----|-------|
| Grafana | http://grafana.127.0.0.1.nip.io | `admin` / `Mikroways123` |
| Products (Node) | http://products.127.0.0.1.nip.io | — |
| Orders (Python) | http://orders.127.0.0.1.nip.io | — |
| Shipping (Java) | http://shipping.127.0.0.1.nip.io | — |
| Faro Shop (frontend) | http://shop.127.0.0.1.nip.io | — |

**Set the stage:**

1. Open **two terminals** side by side with Grafana visible.
2. Start a healthy baseline so graphs aren't empty:
   ```bash
   ./traffic.sh --continuous --fast    # leave running in terminal 1
   ```
3. Pre-open these browser tabs (deep links below).
4. Let it run ~3–4 min so there's history to show before you start talking.

**Deep links (bookmark these):**

| View | Link |
|------|------|
| Platform Home (landing) | `/d/platform-home` |
| Deployment Health (release impact) | `/d/deployment-health` |
| APM (New Relic-style) | `/d/apm-overview` |
| Service Time Breakdown | `/d/service-breakdown` |
| Executive Summary | `/d/executive-dashboard` |
| Service Overview (RED) | `/d/otel-service-overview` |
| Service Map (APM) | `/d/apm-service-map` |
| Distributed Tracing | `/d/super-traces-poc-v1` |
| Log Analysis | `/d/super-logs-poc-v3` |
| Continuous Profiling | `/d/apm-profiling` |
| SLO / Error Budget | `/d/slo-sli-error-budget-v1` |
| Synthetic Monitoring | `/d/synthetic-monitoring` |
| Frontend / RUM | `/d/frontend-rum` |
| k6 Load Testing | `/d/k6-load-testing` |
| Observability Overview | `/d/observability-overview` |
| K8s Cluster Overview | `/d/k8s-cluster-overview` |
| Alerting | `/alerting/list` |
| **Drilldown** (queryless) | nav menu → **Drilldown** |

> All links are relative to `http://grafana.127.0.0.1.nip.io`.

---

## The 12-minute arc

### Act 1 — "One pane of glass" (0:00–1:30)

**Open:** `/d/platform-home`

**Say:**
> "This is a fully open-source observability platform — Grafana, Prometheus,
> Loki, Tempo and Pyroscope. No per-host license, and the data never leaves our
> infrastructure. Everything you'll see replaces a paid Datadog or New Relic
> module. Here are the golden signals for three microservices in different
> languages: Node.js, Python and Java."

**Do:** point at throughput, latency, error rate, and the "currently firing
alerts" panel (quiet = healthy). Click the **Deployment Health** card: the blue
marker is the real `setup.sh` rollout, and the table shows the exact version on
all four workloads. The current impact series are live; on a reused cluster,
select a historical offset that falls before the blue marker to compare. On the
first clean run the older series is correctly absent. Then return to Platform
Home.

---

### Act 2 — "Explore without writing a single query" (1:30–4:00)

This is the headline differentiator. **Open:** nav → **Drilldown** → **Metrics**.

**Say:**
> "Normally exploring metrics means knowing PromQL. With Grafana Drilldown,
> anyone can investigate — point and click."

**Do:**
1. **Metrics Drilldown:** pick `http_server_duration_milliseconds` → break it
   down by `service_name` with one click. No query typed.
2. **Logs Drilldown:** switch to Logs. Show log volume, then drill into
   `products-service` and let it surface error patterns automatically.
3. (Optional) **Traces Drilldown:** show the slowest spans by service.

> Talking point: "Same queryless experience for metrics, logs, traces and
> profiles. This is what shortens mean-time-to-innocence for on-call engineers."

---

### Act 3 — "Inject an incident" (4:00–5:00)

In **terminal 2**, trigger a sustained, realistic degradation:

```bash
./incident.sh -s meltdown -d 600        # errors + latency, 10 minutes
```

**Say:**
> "Let's simulate a partial outage after the release we just inspected. This
> drives real 5xx errors and latency into Products and Orders, while healthy
> traffic keeps flowing, so it looks like a true partial outage, not a
> flatline. The release marker remains trustworthy: this tool changes traffic,
> not code."

The script prints exactly what to watch and the links. Keep it running.

> It drops a red **incident simulation** marker immediately and closes the
> shaded region at the actual stop time (including Ctrl+C). A recovery run gets
> a separate green marker. Real deploys are blue and come only from `setup.sh`
> or `deploy-observe.sh`; all dashboards expose the separate **Deployments**,
> **Incidents** and **Recoveries** annotation toggles.

> Note: alerts have a `for:` window of 2–5 min, so fire the incident now and let
> it build while you narrate Act 4.

---

### Act 4 — "Follow the signal: metric → trace → logs" (5:00–9:00)

**Open:** `/d/otel-service-overview`

**Say:**
> "Within a minute the RED metrics react: error rate climbs, P95 latency
> spikes. A SaaS APM would show the same — but watch how we pivot to root cause."

**Do — the money shot (correlated drill-down):**
1. On a **latency panel**, hover and click an **exemplar** (the little diamond
   on the graph). → Grafana jumps straight to the **exact slow trace** in Tempo.
2. In the trace, open the **waterfall**: show nested spans (the `orders →
   products` cross-service call is real distributed tracing).
3. From a span, click **"Logs for this span"** → Tempo pivots to Loki and shows
   the **logs for that exact request**, correlated by trace ID.
4. **Open:** `/d/apm-service-map` → show the live dependency graph
   (`user → orders → products`) with request rate and errors on the edges.
5. **From a span, click "Profiles for this span"** → opens the CPU/wall **flame
   graph** for that service in Pyroscope (trace → profile). All four signals —
   metrics, logs, traces, profiles — now link to each other.

> Talking point: "Metric, trace, log and profile are one continuous
> investigation — from a graph spike to the exact line of code burning CPU. No
> copy-pasting timestamps across four different tools."

**Profiling (the premium differentiator):** the same flame graph lives on
`/d/apm-profiling`.
> "Continuous profiling — a paid add-on in Datadog/New Relic — included here,
> and wired straight into the trace view."

**The Distributed Tracing dashboard** (`/d/super-traces-poc-v1`) ties it together:
it now opens with the **service map**, **RED metrics derived from spans** (rate,
error % and p95 per service) and a **latency heatmap** — then a trace explorer at
the bottom. Click any errored or slow trace to drop straight into its waterfall,
and from a span use **Logs / Metrics / Profiles for this span**. Same point-and-click
story, no query language, also under **Drilldown → Traces** (now backed by Tempo
TraceQL metrics).

---

### Act 5 — "The alert fires & the budget burns" (9:00–11:00)

**Open:** `/alerting/list`

**Say:**
> "Meanwhile, alerting has been evaluating. The rules just went from *pending*
> to *firing*."

**Do:** show the alerts firing — **High error rate**, **High P95 latency**, and
the **SLO fast burn** (multi-window: 1h *and* 5m burn rate > 14.4x). If a health
endpoint starts returning 503, **Synthetic probe down** fires too. Mention they
would route to Slack/PagerDuty/email via contact points.

**Open:** `/d/slo-sli-error-budget-v1`

**Say:**
> "This is the SRE view: our 99.9% SLO and the error budget. The incident is
> burning the budget fast — at this burn rate the monthly budget is gone in
> days. The multi-window multi-burn-rate alert (Google SRE workbook) only pages
> when both a long and a short window agree, so it catches real burn without
> flapping on a brief blip."

**Do:** point at the **Error-budget burn rate — multi-window** panel: during the
incident the 5m and 1h burn-rate lines shoot well above the **14.4x** threshold
line (that's exactly what pages the fast-burn alert), then fall back after
recovery.

**Optional — synthetic view:** open `/d/synthetic-monitoring` for uptime from
the *outside*; during the incident the failing health check flips that probe to
DOWN, independent of the apps' own metrics.

---

### Act 6 — "Recovery & the pitch" (11:00–12:00)

In terminal 2, stop the incident (Ctrl+C) and run the recovery phase:

```bash
./incident.sh --recover -d 300
```

**Say:**
> "We roll back. Healthy traffic resumes, error rate drops, and within a few
> minutes the alerts resolve and the budget stops burning."

**Close with the value:**
> "Everything you saw — metrics, logs, traces, profiles, the service map,
> alerting, SLOs and queryless exploration — is 100% open source. No per-host
> licensing, your data stays in your infrastructure, and retention is bounded
> by your storage, not a plan tier. The same capability set as a
> five-figure-a-year SaaS APM, running on your own cluster."

Point back to `/d/platform-home` — green again.

---

### Bonus — Frontend RUM & full-stack tracing (the "full-stack" wow)

If you have a couple of minutes more, show that observability reaches the
browser, not just the backend.

**Open:** the **Faro Shop** at http://shop.127.0.0.1.nip.io

**Do:**
1. Click **Load products** and **Place order** a few times, then **Trigger JS
   error** once.
2. **Open:** `/d/frontend-rum` → the JS error appears under *Frontend
   exceptions*, alongside events and Core Web Vitals — all captured by
   **Grafana Faro** in the browser and shipped through **Grafana Alloy**
   (`faro.receiver`) to Loki and Tempo.
3. **The money shot:** open **Traces Drilldown** (or Tempo) and find the latest
   `frontend-shop` trace. The **browser span** for *Place order* links straight
   into `orders-service` → `products-service` — one trace from the click in the
   browser to the backend.

**Say:**
> "Real User Monitoring and full-stack tracing — the browser and the backend in
> one trace. That's the Datadog/New Relic RUM story, fully open source, on our
> own infrastructure."

> Note: the Faro Web SDK is **vendored into the frontend image** (pinned via
> build ARG in `src/frontend-app/Dockerfile`, served same-origin from
> `/vendor`), so the presenter's browser needs **no CDN egress** — it only
> posts RUM data to `faro.127.0.0.1.nip.io`. Web Vitals field names in the
> dashboard may need a tweak once you see real data.

---

## Demo-day notes (read before presenting)

- **Drilldown apps** download from the Grafana plugin catalog on first start, so
  the Grafana pod needs egress to `grafana.com`. If you're fully offline, fall
  back to classic **Explore** for the queryless act.
- **Shipping (Java)** is auto-instrumented with **zero code changes** by the
  **OpenTelemetry Java agent** (baked into the image), so it emits metrics,
  traces and logs on **any kernel** — no BTF required, nothing to verify before
  you present. Beyla (eBPF) is a one-flag opt-in (`beyla.enabled=true`, needs a
  BTF-enabled kernel) to showcase kernel-level instrumentation. `incident.sh`
  still targets Products + Orders by default (their cross-service
  `orders→products` call makes the nicest trace); add `--include-shipping` to
  drive load into Shipping too.
- **Alerts take 2–5 min to fire** (their `for:` window). Trigger the incident
  early (Act 3) and let it build while you talk through Act 4.
- **Tempo** can get slow if many trace queries fire at once; the tracing
  dashboard is already tuned to limit concurrency. If a panel is briefly empty,
  refresh once.
- **Exemplars** need a minute of traffic to appear on histogram panels. The
  baseline `traffic.sh` from prep handles this.
- Want a single-signal story? Use `./incident.sh -s errors` or `-s latency`.

## One-liner cheat sheet

```bash
./setup.sh                              # bring everything up (once)
./traffic.sh --continuous --fast        # healthy baseline (terminal 1)
./incident.sh -s meltdown -d 600        # inject the incident (terminal 2)
./incident.sh --recover -d 300          # recover and clear alerts
./k6.sh --vus 20 --hold 5m              # on-brand load test (k6 -> Prometheus)
```
