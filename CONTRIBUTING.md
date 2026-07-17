# Contributing

Thanks for your interest in improving this observability demo. The bar for
contributions is simple: after your change, `./setup.sh` on a clean machine
must still end with `./check.sh` printing **READY TO DEMO**.

## Getting started

Requirements: Docker (≥20.10), Kind (≥0.20), kubectl (≥1.28), Helm (≥3.12),
Helmfile (≥0.150). Then:

```bash
./setup.sh                 # full cluster + stack + apps (8-12 min first run)
./check.sh                 # readiness check: 4 signals, service map, alerts
./traffic.sh --continuous  # keep telemetry flowing while you work
```

Tear down with `kind delete cluster --name grafana-otel-demo`.

## Repo layout

| Path | What lives there |
|------|------------------|
| `kind/helmfile.d/` + `kind/values/` | Every infra release (ingress, LGTM+P stack, Alloy, blackbox) |
| `kind/dashboards/` | 17 Grafana dashboards as ConfigMaps |
| `charts/` | Helm charts for the 4 demo apps |
| `src/` | App code: Node (OTel SDK 2.x), Python (OTel SDK), Java (no OTel code — Java agent), frontend (Faro) |
| `docs/` | Guides; `DEMO.md` is the 12-minute live-demo script |

## Before opening a PR

Run the same validations CI will run (and reviewers will ask for):

```bash
helm lint charts/*                                   # chart sanity
shellcheck setup.sh traffic.sh incident.sh check.sh k6.sh deploy-observe.sh deployment-snapshot.sh
./deploy-observe.sh --service test-service --version test-1 \
  --status succeeded --dry-run                       # JSON/API payload sanity
docker build src/otel-app && docker build src/otel-python-app \
  && docker build src/shipping-service && docker build src/frontend-app
# If you touched recording rules in kind/values/prometheus.yaml:
#   promtool check rules on the rendered rules
# If you touched anything user-visible: ./setup.sh + ./check.sh
```

Guidelines:

- **Dashboards**: keep UIDs stable (deep links in `DEMO.md` depend on them).
- **Metrics**: the repo intentionally shows two HTTP metric families (SDK
  legacy ms histograms + Java agent stable semconv seconds). If you touch
  queries, keep both sides of the `or` working — `./check.sh` verifies this.
- **Versions**: pin them (charts, images, agents). Renovate keeps them fresh;
  annotate new pins with a `# renovate:` marker (see `renovate.json`).
- **Docs**: if a change alters what a presenter sees or types, update
  `DEMO.md` / `README.md` in the same PR, and add a line to `CHANGELOG.md`.

## Commit style

Conventional-commit style prefixes are used across history: `feat:`, `fix:`,
`docs:`, `chore:`. PRs target `main`.

## Reporting issues

Open a GitHub issue with the output of `./check.sh` and
`kubectl get pods -A` — those two cover most diagnosis.
