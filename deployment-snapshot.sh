#!/usr/bin/env bash
# Capture an immutable-by-convention evidence bundle for a certified deployment.
# The bundle contains no credentials and is created atomically without overwrite.

set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-http://grafana.127.0.0.1.nip.io}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASS="${GRAFANA_PASS:-Mikroways123}"
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"
NAMESPACE="demo"
DEPLOYMENT_ID=""
VERSION=""
ENVIRONMENT="demo"
REVISION="unknown"
STATUS="succeeded"
EVENT_FILE=""
OUTPUT_DIR=""
OUTPUT_ROOT="${DEPLOY_SNAPSHOT_ROOT:-artifacts/deployments}"
WORKLOADS=()
DEFAULT_WORKLOADS=(otel-demo-app otel-python-app shipping-service frontend-app)

usage() {
  cat <<'EOF'
deployment-snapshot.sh — capture auditable post-deployment evidence

Usage:
  ./deployment-snapshot.sh --deployment-id ID --version VERSION \
    --event deployment-event.json [options]

Required:
  --deployment-id ID     Correlation ID used by Kubernetes and Grafana
  --version VERSION      Expected app/image/OTel/Faro release version
  --event FILE           Existing deployment-event.v1 JSON artifact

Options:
  --environment NAME     Expected environment (default: demo)
  --revision SHA         VCS revision recorded in snapshot metadata
  --status STATUS        Expected annotation status (default: succeeded)
  --namespace NAME       Kubernetes namespace (default: demo)
  --workload NAME        Deployment to capture; repeat to override defaults
  --output-dir DIR       Exact destination directory
  --output-root DIR      Parent for <deployment-id> (default: artifacts/deployments)
  -h, --help             Show this help

Authentication:
  GRAFANA_URL             Default: http://grafana.127.0.0.1.nip.io
  GRAFANA_TOKEN           Preferred Bearer token
  GRAFANA_USER/PASS       Basic auth fallback for the local demo

The destination is never overwritten. The bundle is staged next to the target,
verified, checksummed, and renamed atomically into place.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment-id) DEPLOYMENT_ID="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --event) EVENT_FILE="${2:-}"; shift 2 ;;
    --environment) ENVIRONMENT="${2:-}"; shift 2 ;;
    --revision) REVISION="${2:-}"; shift 2 ;;
    --status) STATUS="${2:-}"; shift 2 ;;
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --workload) WORKLOADS+=("${2:-}"); shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --output-root) OUTPUT_ROOT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$DEPLOYMENT_ID" || -z "$VERSION" || -z "$EVENT_FILE" ]]; then
  echo "--deployment-id, --version and --event are required" >&2
  usage >&2
  exit 2
fi
[[ -f "$EVENT_FILE" ]] || { echo "Deployment event not found: $EVENT_FILE" >&2; exit 2; }
case "$STATUS" in
  running|succeeded|failed|cancelled|rolled_back) ;;
  *) echo "Invalid --status '$STATUS'" >&2; exit 2 ;;
esac
if [[ ${#WORKLOADS[@]} -eq 0 ]]; then
  WORKLOADS=("${DEFAULT_WORKLOADS[@]}")
fi
for value in "$DEPLOYMENT_ID" "$VERSION" "$ENVIRONMENT" "$NAMESPACE"; do
  [[ -n "$value" && ! "$value" =~ [[:cntrl:]] ]] || { echo "Snapshot identity contains an invalid control character" >&2; exit 2; }
done
[[ "$DEPLOYMENT_ID" =~ ^[[:alnum:]][[:alnum:]_.:-]{0,127}$ ]] || {
  echo "Deployment ID must use 1-128 alphanumeric, dot, underscore, colon or dash characters" >&2
  exit 2
}
for command in kubectl helm curl base64 sha256sum; do
  command -v "$command" >/dev/null 2>&1 || { echo "Required command not found: $command" >&2; exit 1; }
done

safe_id="$(printf '%s' "$DEPLOYMENT_ID" | tr -cs '[:alnum:]_.-' '-' | sed 's/^-*//;s/-*$//' | cut -c1-120)"
[[ -n "$safe_id" ]] || { echo "Deployment ID cannot form a safe directory name" >&2; exit 2; }
[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="${OUTPUT_ROOT%/}/${safe_id}"
if [[ -e "$OUTPUT_DIR" ]]; then
  echo "Refusing to overwrite existing deployment snapshot: $OUTPUT_DIR" >&2
  exit 1
fi

output_parent="$(dirname "$OUTPUT_DIR")"
output_name="$(basename "$OUTPUT_DIR")"
mkdir -p "$output_parent"
umask 077
staging="$(mktemp -d "${output_parent}/.${output_name}.tmp.XXXXXX")"
auth_headers="$(mktemp)"
chmod 600 "$auth_headers"
cleanup() {
  rm -f "$auth_headers"
  if [[ -n "${staging:-}" && -d "$staging" ]]; then
    rm -rf "$staging"
  fi
}
trap cleanup EXIT

if [[ -n "$GRAFANA_TOKEN" ]]; then
  printf 'Authorization: Bearer %s\n' "$GRAFANA_TOKEN" > "$auth_headers"
else
  basic_auth="$(printf '%s' "${GRAFANA_USER}:${GRAFANA_PASS}" | base64 | tr -d '\n')"
  printf 'Authorization: Basic %s\n' "$basic_auth" > "$auth_headers"
fi

now_ms() {
  local raw
  raw="$(date +%s%N 2>/dev/null || true)"
  if [[ "$raw" =~ ^[0-9]{13,}$ ]]; then
    printf '%s\n' "${raw:0:13}"
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

json_quote() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  if [[ "$s" =~ [[:cntrl:]] ]]; then
    echo "Snapshot metadata contains an unsupported control character" >&2
    return 1
  fi
  printf '"%s"' "$s"
}

grafana_get() {
  local output="$1" path="$2"
  curl -fsS --max-time 20 -H "@${auth_headers}" "${GRAFANA_URL%/}${path}" > "$output"
}

prom_query() {
  local output="$1" query="$2"
  curl -fsS --max-time 20 -G -H "@${auth_headers}" \
    "${GRAFANA_URL%/}/api/datasources/proxy/uid/Prometheus/api/v1/query" \
    --data-urlencode "query=${query}" > "$output"
}

# Validate that the event is the expected schema before copying audit evidence.
grep -Eq '"schema"[[:space:]]*:[[:space:]]*"deployment-event\.v1"' "$EVENT_FILE" || {
  echo "Event is not deployment-event.v1: $EVENT_FILE" >&2
  exit 1
}
for expected in \
  "\"deployment_id\":\"${DEPLOYMENT_ID}\"" \
  "\"status\":\"${STATUS}\"" \
  "\"service_version\":\"${VERSION}\"" \
  "\"deployment_environment_name\":\"${ENVIRONMENT}\""; do
  grep -Fq "$expected" "$EVENT_FILE" || {
    echo "Deployment event identity/status does not match the requested snapshot" >&2
    exit 1
  }
done
cp -- "$EVENT_FILE" "$staging/deployment-event.json"

# Certify live release identity before taking the Kubernetes snapshot.
for workload in "${WORKLOADS[@]}"; do
  actual_version="$(kubectl get deployment "$workload" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}')"
  actual_environment="$(kubectl get deployment "$workload" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.observability\.grafana\.com/environment}')"
  actual_id="$(kubectl get deployment "$workload" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.observability\.grafana\.com/deployment-id}')"
  if [[ "$actual_version" != "$VERSION" || "$actual_environment" != "$ENVIRONMENT" || "$actual_id" != "$DEPLOYMENT_ID" ]]; then
    echo "Release identity mismatch on deployment/$workload" >&2
    exit 1
  fi
  pod_versions="$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=${workload}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.labels.app\.kubernetes\.io/version}{"\n"}{end}' | sed '/^$/d' | sort -u)"
  pod_ids="$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=${workload}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.annotations.observability\.grafana\.com/deployment-id}{"\n"}{end}' | sed '/^$/d' | sort -u)"
  [[ "$pod_versions" == "$VERSION" && "$pod_ids" == "$DEPLOYMENT_ID" ]] || {
    echo "Release identity mismatch or no Running Pods for deployment/$workload" >&2
    exit 1
  }
done

kubectl get deployments "${WORKLOADS[@]}" -n "$NAMESPACE" -o json > "$staging/kubernetes-deployments.json"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/part-of=grafana-otel-demo -o json > "$staging/kubernetes-pods.json"
kubectl get replicasets -n "$NAMESPACE" -l app.kubernetes.io/part-of=grafana-otel-demo -o json > "$staging/kubernetes-replicasets.json"
kubectl get events -n "$NAMESPACE" -o json > "$staging/kubernetes-events.json"
helm list -n "$NAMESPACE" -o json > "$staging/helm-releases.json"

kubectl get deployments "${WORKLOADS[@]}" -n "$NAMESPACE" \
  -o custom-columns='NAME:.metadata.name,VERSION:.metadata.labels.app\.kubernetes\.io/version,DESIRED:.spec.replicas,UPDATED:.status.updatedReplicas,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas,IMAGE:.spec.template.spec.containers[0].image' \
  > "$staging/workloads.txt"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/part-of=grafana-otel-demo \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,IMAGE:.spec.containers[*].image,IMAGE_ID:.status.containerStatuses[*].imageID' \
  > "$staging/pods.txt"
{
  kubectl config current-context
  kubectl version --client=true
  kubectl cluster-info
} > "$staging/cluster.txt"

# Capture the exact Grafana projection plus the dashboard/rules that interpret it.
curl -fsS --max-time 20 -G -H "@${auth_headers}" \
  "${GRAFANA_URL%/}/api/annotations" \
  --data-urlencode 'tags=deployment' --data-urlencode 'limit=1000' \
  > "$staging/grafana-annotations.json"
grep -Fq "id=${DEPLOYMENT_ID}" "$staging/grafana-annotations.json" || {
  echo "Grafana annotation does not contain deployment ID $DEPLOYMENT_ID" >&2
  exit 1
}
grep -Fq "version=${VERSION}" "$staging/grafana-annotations.json" || {
  echo "Grafana annotation does not contain version $VERSION" >&2
  exit 1
}
grep -Fq "status:${STATUS}" "$staging/grafana-annotations.json" || {
  echo "Grafana annotation does not contain status:$STATUS" >&2
  exit 1
}
grafana_get "$staging/grafana-deployment-health-dashboard.json" "/api/dashboards/uid/deployment-health"
grafana_get "$staging/grafana-alert-rules.json" "/api/prometheus/grafana/api/v1/rules"

mkdir -p "$staging/metrics"
cat > "$staging/metrics/queries.tsv" <<EOF
throughput.json	sum(rate(traces_spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m]))
error-ratio.json	job:http_errors:ratio_rate5m
p95-latency-ms.json	1000 * histogram_quantile(0.95, sum by (le) (rate(traces_spanmetrics_latency_bucket{span_kind="SPAN_KIND_SERVER"}[5m])))
apdex.json	job:apdex:ratio5m
synthetic-probes.json	min by (instance) (probe_success)
restarts.json	sum(kube_pod_container_status_restarts_total{namespace="${NAMESPACE}"})
EOF
while IFS=$'\t' read -r filename query; do
  prom_query "$staging/metrics/$filename" "$query"
done < "$staging/metrics/queries.tsv"

captured_at_ms="$(now_ms)"
captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cluster_context="$(kubectl config current-context)"
workloads_json="["
for workload in "${WORKLOADS[@]}"; do
  [[ "$workloads_json" != "[" ]] && workloads_json+=","
  workloads_json+="$(json_quote "$workload")"
done
workloads_json+="]"

cat > "$staging/snapshot.json" <<EOF
{"schema":"deployment-snapshot.v1","deployment_id":$(json_quote "$DEPLOYMENT_ID"),"status":$(json_quote "$STATUS"),"service_version":$(json_quote "$VERSION"),"deployment_environment_name":$(json_quote "$ENVIRONMENT"),"vcs_revision":$(json_quote "$REVISION"),"namespace":$(json_quote "$NAMESPACE"),"cluster_context":$(json_quote "$cluster_context"),"captured_at":$(json_quote "$captured_at"),"captured_at_ms":${captured_at_ms},"workloads":${workloads_json},"integrity_file":"SHA256SUMS"}
EOF

cat > "$staging/README.md" <<EOF
# Deployment snapshot: ${DEPLOYMENT_ID}

- **Schema:** deployment-snapshot.v1
- **Status:** ${STATUS}
- **Version:** ${VERSION}
- **Environment:** ${ENVIRONMENT}
- **Revision:** ${REVISION}
- **Namespace/context:** ${NAMESPACE} / ${cluster_context}
- **Captured:** ${captured_at} (${captured_at_ms} ms)

This atomic bundle is the post-deployment audit evidence for the Grafana
annotation and the Kubernetes release it identifies. Verify integrity with:

\`\`\`bash
sha256sum -c SHA256SUMS
\`\`\`

## Workloads

\`\`\`text
$(cat "$staging/workloads.txt")
\`\`\`

## Pods and immutable image IDs

\`\`\`text
$(cat "$staging/pods.txt")
\`\`\`

The raw JSON files preserve Kubernetes state, Helm releases, Grafana annotations,
the Deployment Health dashboard, managed alert rules and six post-deploy SLIs.
Credentials are never written to this directory.
EOF

(
  cd "$staging"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum
) > "$staging/SHA256SUMS"
(
  cd "$staging"
  sha256sum -c SHA256SUMS >/dev/null
)

mv "$staging" "$OUTPUT_DIR"
staging=""
trap - EXIT
rm -f "$auth_headers"
printf '✓ Deployment snapshot created: %s\n' "$OUTPUT_DIR"
