#!/usr/bin/env bash
# Record a real deployment as a Grafana annotation.
#
# The annotation is intentionally a projection, not the source of audit truth:
# CI/CD should also retain its native deployment record and immutable image
# digest. This script keeps unbounded values (commit, actor, URL, deployment ID)
# in the annotation text/optional JSON artifact, never in Prometheus labels.

set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-${GRAFANA:-http://grafana.127.0.0.1.nip.io}}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASS="${GRAFANA_PASS:-Mikroways123}"
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"

STATUS=""
VERSION=""
ENVIRONMENT="demo"
REVISION="unknown"
ACTOR="${DEPLOY_ACTOR:-${GITHUB_ACTOR:-${GITLAB_USER_LOGIN:-${USER:-unknown}}}}"
SOURCE="${DEPLOY_SOURCE:-manual}"
RUN_URL="${DEPLOY_RUN_URL:-}"
DEPLOYMENT_ID=""
PREVIOUS_VERSION=""
DESCRIPTION=""
STARTED_AT_MS=""
FINISHED_AT_MS=""
OUTPUT=""
BEST_EFFORT=false
DRY_RUN=false
SERVICES=()

usage() {
  cat <<'EOF'
deploy-observe.sh — publish a real deployment marker to Grafana

Usage:
  ./deploy-observe.sh --service NAME [--service NAME ...] --version VERSION \
    --status succeeded|failed|cancelled|rolled_back [options]

Required:
  --service NAME          Service affected; repeat for a release with many services
  --version VERSION       Human release version (SemVer, Git SHA, or release ID)
  --status STATUS         succeeded | failed | cancelled | rolled_back | running

Metadata:
  --environment NAME      Deployment environment (default: demo)
  --revision SHA          VCS revision (kept in text, not a tag)
  --deployment-id ID      Correlation ID (generated when omitted)
  --previous-version VER  Version replaced by this deployment
  --actor ID              Opaque user/automation ID (default from CI or $USER)
  --source NAME           setup.sh, github-actions, gitlab-ci, argocd, manual...
  --run-url URL           Link to the CI/CD run
  --description TEXT      Short free-form context
  --started-at-ms EPOCH   Deployment start, Unix epoch milliseconds
  --finished-at-ms EPOCH  Deployment end, Unix epoch milliseconds
  --output FILE           Write deployment-event.v1 JSON for CI artifacts

Delivery:
  GRAFANA_URL              Default: http://grafana.127.0.0.1.nip.io
  GRAFANA_TOKEN            Preferred bearer/service-account token for CI/CD
  GRAFANA_USER/PASS        Basic auth fallback for this local demo only
  --best-effort            Do not fail the caller if Grafana is unavailable
  --dry-run                Print payloads without calling Grafana

Examples:
  ./deploy-observe.sh --service products-service --version v2.3.1 \
    --status succeeded --revision "$(git rev-parse HEAD)"

  GRAFANA_TOKEN="$TOKEN" ./deploy-observe.sh \
    --service orders-service --version "$CI_COMMIT_TAG" --status failed \
    --source gitlab-ci --run-url "$CI_PIPELINE_URL" --output deployment.json
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) SERVICES+=("${2:-}"); shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --status) STATUS="${2:-}"; shift 2 ;;
    --environment) ENVIRONMENT="${2:-}"; shift 2 ;;
    --revision) REVISION="${2:-}"; shift 2 ;;
    --deployment-id) DEPLOYMENT_ID="${2:-}"; shift 2 ;;
    --previous-version) PREVIOUS_VERSION="${2:-}"; shift 2 ;;
    --actor) ACTOR="${2:-}"; shift 2 ;;
    --source) SOURCE="${2:-}"; shift 2 ;;
    --run-url) RUN_URL="${2:-}"; shift 2 ;;
    --description) DESCRIPTION="${2:-}"; shift 2 ;;
    --started-at-ms) STARTED_AT_MS="${2:-}"; shift 2 ;;
    --finished-at-ms) FINISHED_AT_MS="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --best-effort) BEST_EFFORT=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ${#SERVICES[@]} -eq 0 || -z "$VERSION" || -z "$STATUS" ]]; then
  echo "--service, --version and --status are required" >&2
  usage >&2
  exit 2
fi
case "$STATUS" in
  succeeded|failed|cancelled|rolled_back|running) ;;
  *) echo "Invalid --status '$STATUS'" >&2; exit 2 ;;
esac

now_ms() {
  local raw
  raw="$(date +%s%N 2>/dev/null || true)"
  if [[ "$raw" =~ ^[0-9]{13,}$ ]]; then
    printf '%s\n' "${raw:0:13}"
  else
    # BusyBox and other minimal date implementations may not support %N.
    printf '%s000\n' "$(date +%s)"
  fi
}
[[ -n "$STARTED_AT_MS" ]] || STARTED_AT_MS="$(now_ms)"
if [[ "$STATUS" == "running" ]]; then
  [[ -n "$FINISHED_AT_MS" ]] || FINISHED_AT_MS="$STARTED_AT_MS"
else
  [[ -n "$FINISHED_AT_MS" ]] || FINISHED_AT_MS="$(now_ms)"
fi
for value in "$STARTED_AT_MS" "$FINISHED_AT_MS"; do
  [[ "$value" =~ ^[0-9]{13}$ ]] || { echo "timestamps must be exactly 13-digit Unix epoch milliseconds" >&2; exit 2; }
done
(( FINISHED_AT_MS >= STARTED_AT_MS )) || { echo "finished time precedes started time" >&2; exit 2; }

[[ -n "$DEPLOYMENT_ID" ]] || DEPLOYMENT_ID="dep-$(date -u +%Y%m%dT%H%M%SZ)-$$"
DURATION_MS=$(( FINISHED_AT_MS - STARTED_AT_MS ))

# JSON encoder for scalar strings. Avoids jq/Python as host prerequisites.
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
    echo "metadata contains an unsupported control character" >&2
    return 1
  fi
  printf '"%s"' "$s"
}

# Tags are indexed by Grafana. Keep them bounded and low-cardinality; release
# versions, commits, actors, run URLs and deployment IDs remain in text/JSON.
tag_value() {
  printf '%s' "$1" | tr -cs '[:alnum:]_.-' '-' | sed 's/^-*//;s/-*$//' | cut -c1-80
}

services_text=""
services_json="["
tags=("deployment" "status:$(tag_value "$STATUS")" "env:$(tag_value "$ENVIRONMENT")" "source:$(tag_value "$SOURCE")")
[[ "$STATUS" == "succeeded" ]] && tags+=("release")
for service in "${SERVICES[@]}"; do
  [[ -n "$service" ]] || { echo "service names must not be empty" >&2; exit 2; }
  [[ -n "$services_text" ]] && services_text+=", "
  services_text+="$service"
  [[ "$services_json" != "[" ]] && services_json+=","
  services_json+="$(json_quote "$service")"
  tags+=("service:$(tag_value "$service")")
done
services_json+="]"

tags_json="["
for tag in "${tags[@]}"; do
  [[ "$tags_json" != "[" ]] && tags_json+=","
  tags_json+="$(json_quote "$tag")"
done
tags_json+="]"

status_label="${STATUS//_/ }"
text="Deployment ${status_label}: ${services_text} · version=${VERSION} · env=${ENVIRONMENT} · revision=${REVISION} · actor=${ACTOR} · duration=${DURATION_MS}ms · id=${DEPLOYMENT_ID}"
[[ -n "$PREVIOUS_VERSION" ]] && text+=" · previous=${PREVIOUS_VERSION}"
[[ -n "$SOURCE" ]] && text+=" · source=${SOURCE}"
[[ -n "$RUN_URL" ]] && text+=" · run=${RUN_URL}"
[[ -n "$DESCRIPTION" ]] && text+=" · ${DESCRIPTION}"

annotation_payload="{\"time\":${STARTED_AT_MS}"
if (( FINISHED_AT_MS > STARTED_AT_MS )); then
  annotation_payload+=",\"timeEnd\":${FINISHED_AT_MS}"
fi
annotation_payload+=",\"tags\":${tags_json},\"text\":$(json_quote "$text")}"

event_payload="{\"schema\":\"deployment-event.v1\",\"deployment_id\":$(json_quote "$DEPLOYMENT_ID"),\"status\":$(json_quote "$STATUS"),\"started_at_ms\":${STARTED_AT_MS},\"finished_at_ms\":${FINISHED_AT_MS},\"duration_ms\":${DURATION_MS},\"services\":${services_json},\"service_version\":$(json_quote "$VERSION"),\"deployment_environment_name\":$(json_quote "$ENVIRONMENT"),\"vcs_revision\":$(json_quote "$REVISION"),\"previous_version\":$(json_quote "$PREVIOUS_VERSION"),\"actor_id\":$(json_quote "$ACTOR"),\"source\":$(json_quote "$SOURCE"),\"run_url\":$(json_quote "$RUN_URL"),\"description\":$(json_quote "$DESCRIPTION")}"

if [[ -n "$OUTPUT" ]]; then
  umask 077
  mkdir -p "$(dirname "$OUTPUT")"
  printf '%s\n' "$event_payload" > "$OUTPUT"
fi

if [[ "$DRY_RUN" == true ]]; then
  printf '%s\n' "$event_payload"
  printf '%s\n' "$annotation_payload"
  exit 0
fi

tmp="$(mktemp)"
auth_headers="$(mktemp)"
chmod 600 "$auth_headers"
trap 'rm -f "$tmp" "$auth_headers"' EXIT
if [[ -n "$GRAFANA_TOKEN" ]]; then
  printf 'Authorization: Bearer %s\n' "$GRAFANA_TOKEN" > "$auth_headers"
else
  basic_auth="$(printf '%s' "${GRAFANA_USER}:${GRAFANA_PASS}" | base64 | tr -d '\n')"
  printf 'Authorization: Basic %s\n' "$basic_auth" > "$auth_headers"
fi
curl_args=(
  -sS -m 10 -o "$tmp" -w '%{http_code}'
  -H 'Content-Type: application/json'
  -H "@${auth_headers}"
  -X POST --data-binary "$annotation_payload"
)

http_code="$(curl "${curl_args[@]}" "${GRAFANA_URL%/}/api/annotations" 2>/dev/null || true)"
if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
  annotation_id="$(sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$tmp" | head -1)"
  echo "✓ Deployment annotation created${annotation_id:+ (id=${annotation_id})}: ${services_text} ${VERSION} [${STATUS}]"
  exit 0
fi

echo "Failed to create deployment annotation (HTTP ${http_code:-000}): $(cat "$tmp" 2>/dev/null)" >&2
[[ "$BEST_EFFORT" == true ]] && exit 0
exit 1
