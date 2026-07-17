# Deployment Observability

A deployment is an operational event, not just a CI log line. This demo records
real releases in Grafana and propagates one release identity through Kubernetes,
OpenTelemetry and Faro so an operator can answer:

- **what** changed (`service.version`, image tag and digest);
- **where** it changed (`deployment.environment.name`, namespace and service);
- **when** the rollout started/finished and how long it took;
- **whether** it succeeded or failed;
- **what happened next** to error rate, latency, Apdex, probes and restarts.

Open **Deployment Health** (`/d/deployment-health`) to compare current signals
with a selectable historical offset. Blue annotations are real deployments;
red regions are incident simulations and green markers are recovery traffic.
The offset is a relative comparison, not automatically anchored to a selected
annotation: on the first clean setup there is no older app telemetry, so only
the current series is expected. After history exists, choose an offset that
lands before the marker; an exact automated pre/post assessment belongs in the
CI/CD pipeline using the event timestamps.

## Automatic local flow

`setup.sh` does all of this automatically:

1. Builds each app with a unique-by-default tag such as
   `git-a1b2c3d4e5f6-1784224922432` (override with `DEPLOY_VERSION`).
2. Loads and deploys that exact tag, which guarantees a new Kubernetes rollout
   when the generated tag changes, even if a Kind cluster is reused.
3. Adds the same bounded identity to Deployment and Pod labels/annotations.
4. Exposes it as backend `service.version` and Faro `app.version`.
5. Runs `check.sh`; the setup no longer prints READY for partially-ready pods.
6. Calls `deploy-observe.sh` with actual start/end timestamps only after the
   post-deploy check passes. An `EXIT` trap records `failed` if build, Helm or
   readiness aborts; failure to write the success annotation fails the setup.

Optional environment overrides:

```bash
DEPLOY_VERSION=v2.4.0 \
DEPLOY_ENVIRONMENT=staging \
DEPLOY_ACTOR=platform-bot \
DEPLOY_RUN_URL=https://ci.example/runs/4815 \
./setup.sh
```

`DEPLOY_VERSION` and `DEPLOY_ENVIRONMENT` must be Kubernetes-label safe. The
full Git revision remains in annotations/event text; it is intentionally not a
metric label.

## Auditable deployment snapshots

After the succeeded annotation is accepted, `setup.sh` creates an atomic bundle
at `artifacts/deployments/<deployment-id>/`. It is evidence for the exact
post-deploy state, not another telemetry stream:

- `deployment-event.json` (`deployment-event.v1`) and `snapshot.json`
  (`deployment-snapshot.v1`);
- raw Deployments, Pods, ReplicaSets and namespace events, including image IDs;
- Helm release metadata and human-readable workload/Pod summaries;
- the matching Grafana deployment annotations, Deployment Health dashboard and
  current Grafana-managed alert rules;
- six Prometheus API responses: throughput, error ratio, P95, Apdex, synthetic
  probes and restarts;
- `SHA256SUMS`, generated and verified before the temporary directory is renamed
  atomically into place.

The destination is never overwritten and credentials are kept in a temporary
`0600` header file outside the bundle. Runtime snapshots are ignored by Git;
upload the whole directory as a CI artifact and run
`sha256sum -c SHA256SUMS` when consuming it. Disable local capture only when
needed with `DEPLOY_SNAPSHOT_ENABLED=0`, or change its parent with
`DEPLOY_SNAPSHOT_ROOT=/path/to/artifacts`.

To capture a certified release outside `setup.sh`:

```bash
./deployment-snapshot.sh \
  --deployment-id "$DEPLOYMENT_ID" \
  --version "$RELEASE_VERSION" \
  --environment production \
  --revision "$CI_COMMIT_SHA" \
  --event deployment-event.json \
  --output-dir "artifacts/deployments/$DEPLOYMENT_ID"
```

The script refuses mismatched Deployment/Pod identities, a missing matching
Grafana annotation, malformed event schema or an existing destination.

## Record a deployment from any pipeline

`deploy-observe.sh` is independent of Helm and Kubernetes. Call it after the
pipeline knows the terminal result:

```bash
started_ms=$(($(date +%s) * 1000))
status=succeeded

if ! helm upgrade --install products ./chart --wait; then
  status=failed
fi

GRAFANA_URL=https://grafana.example.com \
GRAFANA_TOKEN="$GRAFANA_DEPLOY_TOKEN" \
./deploy-observe.sh \
  --service products-service \
  --version "$RELEASE_VERSION" \
  --environment production \
  --revision "$CI_COMMIT_SHA" \
  --deployment-id "$CI_PIPELINE_ID-products" \
  --actor "$CI_ACTOR_ID" \
  --source gitlab-ci \
  --run-url "$CI_PIPELINE_URL" \
  --status "$status" \
  --started-at-ms "$started_ms" \
  --finished-at-ms "$(($(date +%s) * 1000))" \
  --output deployment-event.json

[ "$status" = succeeded ]
```

Repeat `--service` to represent a coordinated release. `--output` writes a
`deployment-event.v1` JSON artifact; retain it in CI because Grafana annotations
are a visual projection, not an immutable audit database.

### Authentication

- Local demo: Basic auth defaults to `admin` / `Mikroways123` over local HTTP.
- CI/CD: set `GRAFANA_TOKEN` to a least-privilege Grafana service-account token
  and use HTTPS. Do not pass tokens as command-line arguments or enable `set -x`.
- Use `--best-effort` only when observability must not block a local demo. For a
  controlled production deployment, inability to write the initial/terminal
  deployment record should be handled explicitly by policy.

## Metadata contract

| Layer | Bounded/queryable identity | Full audit context |
|---|---|---|
| Kubernetes | `app.kubernetes.io/version`, `observability.grafana.com/service-name`, `.../environment` | annotations: revision, deployment ID, deployed-at |
| OTel metrics/traces/logs | `service.name`, `service.namespace`, `service.version`, `deployment.environment.name` | no actor/commit/run ID on every telemetry item |
| Faro | app name, version and environment | browser session/trace metadata |
| Grafana annotation | tags: deployment, status, environment, service, source | text: version, revision, actor, duration, run URL, deployment ID |
| CI artifact | service/version/environment | complete `deployment-event.v1` JSON |

Alloy promotes the bounded OTel resource identity to Prometheus labels. The
node-log Alloy DaemonSet also maps the canonical Pod labels to
`service_name`, `service_version` and `deployment_environment_name` in Loki.

## Cardinality rules

This deployment feature never adds full Git SHA, deployment ID, actor, branch,
pipeline URL or deploy timestamps as metric/Loki stream labels: those values
grow without bound and belong in the single event, Kubernetes annotations and
CI artifact. The existing generic Alloy `k8sattributes` pipeline also promotes
pod UID/name/start time through `resource_to_telemetry_conversion`; for a
production profile, add an explicit metric-resource allowlist/drop transform.
That broader pipeline-cardinality hardening is outside this demo feature.

`service.version` does create one set of series/streams per retained release; it
is an intentional, controlled dimension for release comparison, not an
unbounded audit label. Aggregate without version by default and select it only
during rollout/canary analysis.

## Incident simulations are not deployments

`incident.sh` only generates traffic. It now writes `incident`/`simulation` and
`recovery` annotations; it no longer invents a deploy or rollback. This keeps the
release history trustworthy. Its final incident region uses the actual stop time,
including when interrupted with Ctrl+C.
