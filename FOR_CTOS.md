# Observability you own

A short brief for engineering leaders who already run Datadog or New Relic and
want to understand what changes if they bring observability in-house.

You already know what good observability looks like, because you pay Datadog or
New Relic for it every month. You also know the parts that hurt. The bill climbs
with every host and every gigabyte of logs. Your telemetry lives in a vendor's
cloud. Your instrumentation is tied to their agent, so leaving means
re-instrumenting everything you have.

This project is the same picture, built on open source you run yourself: APM
with Apdex scores, distributed traces, real user monitoring in the browser, SLO
burn-rate alerts, and code-level profiling. No per-host license. The telemetry
never leaves your network. The instrumentation is OpenTelemetry, an open
standard, so it stays portable if you ever want to move back to a vendor or run
both at once.

## If you know New Relic or Datadog, you already know this

Every capability here has a name you recognize from the tools you use now. What
changes is who hosts it and who sends the invoice.

| What you rely on today | What it is called here | Open-source engine |
|---|---|---|
| APM summary: Apdex, throughput, error rate | APM dashboard | Prometheus + Grafana |
| Transaction time breakdown (database vs app vs external call) | Service Time Breakdown | Tempo span metrics |
| Distributed tracing and flame graphs | Distributed tracing | Tempo |
| Browser monitoring / RUM | Faro Shop | Grafana Faro |
| Synthetic checks | Synthetic monitoring | Blackbox exporter |
| SLOs and error-budget alerts | Multi-window burn-rate alerts | Prometheus rules |
| Continuous profiling | CPU and wall flame graphs | Pyroscope |
| Log search | Log analysis | Loki |
| Dashboards | Dashboards | Grafana |

If some of the engine names in the third column are new to you, set them aside.
Prometheus stores metrics, Loki stores logs, Tempo stores traces, Pyroscope
stores profiles, and Grafana is the single screen that ties them together, the
way the Datadog or New Relic console is your single screen today. Alloy is the
agent that collects the data, the equivalent of the vendor agent you install on
each host.

Two things worth showing a skeptic on your team. The Java service in the demo
is fully traced with no code changes, the same auto-instrumentation the
commercial agents promise. And one click in the browser produces a single trace
that runs from the web page, into the orders service, and down into the products
service, so a slow checkout is one clickable path instead of four disconnected
tools.

## The math

The reference case below is a mid-size deployment: 50 hosts and 100 GB of logs a
month, with full APM.

| Solution | Annual cost | Where your data lives |
|---|---|---|
| Datadog | $45,000 to $75,000 | Datadog cloud |
| New Relic | $35,000 to $60,000 | New Relic cloud |
| This stack | $5,000 to $15,000 all-in | Your infrastructure |

The honest version of that last row: the licensing is zero, but self-hosting is
not free. The infrastructure runs about $4,200 a year on AWS for this reference
size, and you should budget half to one engineer's time to run the platform.
That labor is most of the cost, and it is the number vendors count on you not
counting. Even with it included, the three-year total tells the story.

| Solution | Three-year total cost of ownership |
|---|---|
| Datadog Enterprise | $225,000 |
| New Relic Pro | $144,000 |
| Self-hosted, including setup and support | $55,000 |

The gap widens as you grow. Metered pricing charges you more for every host and
every gigabyte you add, while your own infrastructure cost stays close to flat.
The full breakdown, including a break-even calculation, is in
[docs/COST_ANALYSIS.md](docs/COST_ANALYSIS.md).

## What you actually keep

Your telemetry stays inside your network. That is the line your security and
compliance teams care about for GDPR, HIPAA, and SOC 2, because there is no
third party holding your logs and traces.

You keep as much history as your storage allows, instead of the 8 to 15 days
most plans include before you start paying for extended retention.

You stay on an open standard. Because the services are instrumented with
OpenTelemetry rather than a proprietary agent, a future price increase never
turns into a re-instrumentation project. The dashboards, the alerts, and the
instrumentation are yours to keep.

## The honest part

This is unlicensed, not effortless, and a good decision should account for both.

You are taking on the uptime of your observability stack. If it breaks at 2
a.m., that is your on-call rotation, not a vendor's support desk. Grafana Labs
sells commercial support for this exact set of tools if you want a backstop, so
self-hosted does not have to mean unsupported, but that is a choice you make on
purpose.

The demo runs on a single local cluster to show the features clearly. A real
deployment needs persistent storage, replicas across zones, TLS, and single
sign-on, which [docs/PRODUCTION.md](docs/PRODUCTION.md) walks through.

A vendor can still be the right answer. If your team is small and has nobody to
spare for platform work, or you are optimizing for speed on a short project, the
monthly bill may be cheaper than the attention self-hosting asks for. You can
even run this next to your current vendor on the same OpenTelemetry data while
you decide, with no re-instrumentation either way.

Where self-hosting tends to win is the case this demo is built for: 50 or more
hosts, real data-sovereignty requirements, high log volume, and a team that
already runs Kubernetes.

## See it for yourself

Clone the repo and run `./setup.sh`. The whole stack comes up on your laptop in
a few minutes, with no changes to `/etc/hosts`. Then open [DEMO.md](DEMO.md) and
follow the 12-minute walk-through of a real incident: an error rate climbs, you
follow one slow request from the metric to the trace to the exact log line, the
SLO budget burns on screen, and then it recovers. It is the same investigation
you would run in Datadog or New Relic, on a stack you would own.
