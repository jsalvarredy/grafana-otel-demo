#!/usr/bin/env bash
# ============================================================================
# Demo readiness check — validate the whole observability story is GREEN
# before you present. Run it after ./setup.sh (and after generating a little
# traffic). It checks the four signals (metrics, logs, traces, profiles), the
# service map, exemplars, the Drilldown plugins and the alert state, and prints
# a clear READY / NOT READY verdict.
#
# Usage:
#   ./check.sh                 # warm up with a little traffic, then check
#   ./check.sh --no-warmup     # check only (assumes traffic already flowing)
#
# Env overrides:
#   GRAFANA_URL  (default http://grafana.127.0.0.1.nip.io)
#   GRAFANA_USER (default admin)
#   GRAFANA_PASS (default Mikroways123)
# Exit code: 0 if all hard checks pass, 1 otherwise.
# ============================================================================

GRAFANA_URL="${GRAFANA_URL:-http://grafana.127.0.0.1.nip.io}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASS="${GRAFANA_PASS:-Mikroways123}"
AUTH="${GRAFANA_USER}:${GRAFANA_PASS}"
INGRESS_HOST="${INGRESS_HOST:-localhost}"
WARMUP=1
DEPLOYMENT_ANNOTATION_REQUIRED="${DEPLOYMENT_ANNOTATION_REQUIRED:-1}"
[ "${1:-}" = "--no-warmup" ] && WARMUP=0

# Use the repo's kubeconfig if present and none is set.
if [ -z "${KUBECONFIG:-}" ] && [ -f "$PWD/kind/.kube/config" ]; then
  export KUBECONFIG="$PWD/kind/.kube/config"
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0

section(){ echo ""; echo -e "${CYAN}── $1 ──${NC}"; }
ok(){   echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
bad(){  echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL+1)); }
warn(){ echo -e "  ${YELLOW}⚠${NC}  $1"; WARN=$((WARN+1)); }
info(){ echo -e "  ${BLUE}ℹ${NC}  $1"; }

# Instant PromQL query via the Grafana datasource proxy; prints the scalar value
# of the first result (empty if no data).
promq(){
  curl -s -G -u "$AUTH" "$GRAFANA_URL/api/datasources/proxy/uid/Prometheus/api/v1/query" \
    --data-urlencode "query=$1" 2>/dev/null \
    | sed -nE 's/.*"value":\[[0-9.]+,"([0-9.eE+-]+)"\].*/\1/p' | head -1
}
# Loki instant metric query; prints scalar value (empty if no data).
lokiq(){
  curl -s -G -u "$AUTH" "$GRAFANA_URL/api/datasources/proxy/uid/Loki/loki/api/v1/query" \
    --data-urlencode "query=$1" 2>/dev/null \
    | sed -nE 's/.*"value":\[[0-9.]+,"([0-9.eE+-]+)"\].*/\1/p' | head -1
}
# Is value >= 1 ?
ge1(){ awk -v v="${1:-0}" 'BEGIN{exit !(v+0>=1)}'; }

echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Grafana Observability Demo — Readiness Check${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"

# ---------------------------------------------------------------------------
# Optional warm-up: a little traffic so "recent" signals (exemplars, live map
# edges) are present for the check.
# ---------------------------------------------------------------------------
if [ "$WARMUP" = "1" ]; then
  section "Warm-up traffic (use --no-warmup to skip)"
  req(){ curl -s -o /dev/null -H "Host: $1" "http://${INGRESS_HOST}${2}" 2>/dev/null || true; }
  reqp(){ curl -s -o /dev/null -X POST -H "Host: $1" -H 'Content-Type: application/json' -d "$3" "http://${INGRESS_HOST}${2}" 2>/dev/null || true; }
  for _ in $(seq 1 20); do
    req  "products.127.0.0.1.nip.io" "/api/products"
    req  "products.127.0.0.1.nip.io" "/api/products/$((RANDOM%8+1))"
    reqp "orders.127.0.0.1.nip.io"   "/api/orders" "{\"product_id\":$((RANDOM%8+1)),\"quantity\":1,\"user_id\":\"chk-$RANDOM\"}"
    reqp "shipping.127.0.0.1.nip.io" "/api/shipping/quote" "{\"origin\":\"NY\",\"destination\":\"LA\",\"weight\":$((RANDOM%40+1))}"
    req  "shipping.127.0.0.1.nip.io" "/api/"
    echo -n "."
  done
  echo " done"
  info "Waiting 15s for metrics/traces to be scraped & generated..."
  sleep 15
fi

# ---------------------------------------------------------------------------
section "Platform"
# ---------------------------------------------------------------------------
if command -v kubectl >/dev/null 2>&1; then
  check_namespace_ready(){
    local ns="$1" label="$2" rows bad_rows
    if ! rows=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null); then
      bad "Cannot query pods in namespace $ns"
      return
    fi
    if [ -z "$rows" ]; then
      bad "No pods found in namespace $ns"
      return
    fi
    # STATUS=Running is insufficient: a pod can be 1/2 Running while one
    # container is CrashLoopBackOff. Require READY current == total.
    bad_rows=$(printf '%s\n' "$rows" | awk '
      $3 == "Completed" { next }
      { split($2, ready, "/"); if ($3 != "Running" || ready[1] != ready[2]) print $1 " (" $2 ", " $3 ")" }
    ')
    if [ -z "$bad_rows" ]; then
      ok "All $label pods fully Ready"
    else
      bad "$label pod(s) not fully Ready: $(printf '%s' "$bad_rows" | paste -sd ';' -)"
    fi
  }
  check_namespace_ready monitoring monitoring
  check_namespace_ready demo demo
else
  warn "kubectl not found — skipping pod checks"
fi

gver=$(curl -s -u "$AUTH" "$GRAFANA_URL/api/health" 2>/dev/null | sed -nE 's/.*"version":[[:space:]]*"([^"]+)".*/\1/p')
if [ -n "$gver" ]; then ok "Grafana reachable (v$gver)"; else bad "Grafana not reachable at $GRAFANA_URL"; fi

# ---------------------------------------------------------------------------
section "Deployment observability"
# ---------------------------------------------------------------------------
if command -v kubectl >/dev/null 2>&1; then
  release_versions=""
  release_bad=0
  release_version=""
  release_deployment_id=""
  for deployment in otel-demo-app otel-python-app shipping-service frontend-app; do
    version=$(kubectl get deployment "$deployment" -n demo -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || true)
    deployment_id=$(kubectl get deployment "$deployment" -n demo -o jsonpath='{.metadata.annotations.observability\.grafana\.com/deployment-id}' 2>/dev/null || true)
    pod_versions=$(kubectl get pods -n demo -l "app.kubernetes.io/instance=$deployment" --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.metadata.labels.app\.kubernetes\.io/version}{"\n"}{end}' 2>/dev/null | sed '/^$/d' | sort -u || true)
    if [ -z "$version" ] || [ "$pod_versions" != "$version" ] || [ -z "$deployment_id" ]; then
      release_bad=$((release_bad+1))
      continue
    fi
    if { [ -n "$release_version" ] && [ "$release_version" != "$version" ]; } || \
       { [ -n "$release_deployment_id" ] && [ "$release_deployment_id" != "$deployment_id" ]; }; then
      release_bad=$((release_bad+1))
      continue
    fi
    release_version="$version"
    release_deployment_id="$deployment_id"
    release_versions="${release_versions}${deployment}=${version} "
  done
  if [ "$release_bad" -eq 0 ]; then
    ok "Release ${release_version} / ${release_deployment_id} is consistent on all Deployments and Running Pods"
  else
    bad "$release_bad app deployment(s) have mismatching version/deployment ID or stale Running Pods"
  fi
else
  release_version=""
  release_deployment_id=""
  warn "kubectl not found — skipping release label checks"
fi

if [ "$DEPLOYMENT_ANNOTATION_REQUIRED" = "0" ]; then
  info "Deployment annotation check deferred until post-deploy verification completes"
else
  annotations=$(curl -s -G -u "$AUTH" "$GRAFANA_URL/api/annotations" \
    --data-urlencode 'tags=deployment' --data-urlencode 'limit=100' 2>/dev/null || true)
  if [ -n "$release_deployment_id" ] && \
     echo "$annotations" | grep -Fq "id=${release_deployment_id}" && \
     echo "$annotations" | grep -Fq "version=${release_version}" && \
     echo "$annotations" | grep -Fq 'status:succeeded'; then
    ok "Grafana annotation matches current release ${release_deployment_id} (${release_version}, succeeded)"
  else
    bad "No succeeded Grafana annotation matches the deployment ID/version currently running"
  fi
fi

# ---------------------------------------------------------------------------
section "Metrics signal (RED)"
# ---------------------------------------------------------------------------
for svc in products-service orders-service; do
  v=$(promq "count(http_requests_total{service_name=\"$svc\"})")
  if ge1 "$v"; then ok "SDK metrics present: $svc"; else bad "No http_requests_total for $svc"; fi
done
# Shipping is the P0 fix: it must now emit via the OTel Java agent (any kernel).
vs=$(promq 'count(http_server_request_duration_seconds_count{service_name="shipping-service"})')
if ge1 "$vs"; then
  ok "shipping-service emitting HTTP metrics (OTel Java agent)"
else
  bad "shipping-service has NO HTTP metrics (Java agent down? Beyla without BTF?)"
fi

# ---------------------------------------------------------------------------
section "Traces signal & Service Map"
# ---------------------------------------------------------------------------
for svc in products-service orders-service shipping-service; do
  v=$(promq "count(last_over_time(traces_service_graph_request_total{server=\"$svc\"}[1h]))")
  if ge1 "$v"; then ok "Tempo traces reaching $svc (service graph)"; else warn "No traces into $svc in last 1h (needs recent traffic)"; fi
done
edge=$(promq 'count(last_over_time(traces_service_graph_request_total{client="orders-service",server="products-service"}[1h]))')
if ge1 "$edge"; then ok "Service map edge orders-service → products-service"; else warn "Cross-service edge not seen in last 1h (place an order)"; fi

# ---------------------------------------------------------------------------
section "Logs signal"
# ---------------------------------------------------------------------------
for svc in products-service orders-service shipping-service; do
  v=$(lokiq "sum(count_over_time({service_name=\"$svc\"}[1h]))")
  if ge1 "$v"; then ok "Loki has logs: $svc"; else bad "No logs in Loki for $svc"; fi
done

# ---------------------------------------------------------------------------
section "Profiles signal"
# ---------------------------------------------------------------------------
NOW=$(date +%s)000; FROM=$(( $(date +%s) - 3600 ))000
prof=$(curl -s -u "$AUTH" "$GRAFANA_URL/api/datasources/proxy/uid/Pyroscope/querier.v1.QuerierService/LabelValues" \
  -H 'Content-Type: application/json' -d "{\"name\":\"service_name\",\"start\":${FROM},\"end\":${NOW}}" 2>/dev/null)
# products-service pushes via the Node.js SDK; shipping-service via the
# Pyroscope Java agent (second -javaagent, zero code changes).
for svc in products-service shipping-service; do
  if echo "$prof" | grep -q "$svc"; then ok "Pyroscope has profiles ($svc)"; else warn "No profiles found yet for $svc"; fi
done

# ---------------------------------------------------------------------------
section "Correlation: exemplars (metric → trace)"
# ---------------------------------------------------------------------------
# Exemplars come from Tempo's span metrics (metrics-generator remote-writes
# them with send_exemplars: true) - that is what the APM latency panels use.
# The apps' own JS histograms carry none: the OTel JS SDK does not wire
# OTEL_METRICS_EXEMPLAR_FILTER yet (unlike Java/Python).
ex=""
for fam in traces_spanmetrics_latency_bucket http_server_duration_milliseconds_bucket; do
  ex=$(curl -s -G -u "$AUTH" "$GRAFANA_URL/api/datasources/proxy/uid/Prometheus/api/v1/query_exemplars" \
    --data-urlencode "query=$fam" \
    --data-urlencode "start=$(( $(date +%s) - 900 ))" --data-urlencode "end=$(date +%s)" 2>/dev/null \
    | grep -oE '"traceID":"[a-f0-9]+"' | head -1)
  [ -n "$ex" ] && break
done
if [ -n "$ex" ]; then ok "Exemplars present on latency metrics (span metrics)"; else warn "No exemplars in last 15m (need traffic with sampled traces)"; fi

# ---------------------------------------------------------------------------
section "Drilldown apps (queryless)"
# ---------------------------------------------------------------------------
plugins=$(curl -s -u "$AUTH" "$GRAFANA_URL/api/plugins?embedded=0" 2>/dev/null)
for p in grafana-metricsdrilldown-app grafana-lokiexplore-app grafana-exploretraces-app grafana-pyroscope-app; do
  if echo "$plugins" | grep -q "\"id\":\"$p\""; then ok "Plugin installed: $p"; else warn "Drilldown plugin missing: $p (needs egress to grafana.com)"; fi
done

# ---------------------------------------------------------------------------
section "Alerting"
# ---------------------------------------------------------------------------
rules=$(curl -s -u "$AUTH" "$GRAFANA_URL/api/prometheus/grafana/api/v1/rules" 2>/dev/null)
firing=$(echo "$rules" | grep -oE '"state":"firing"' | wc -l | tr -d ' ')
if [ "${firing:-0}" = "0" ]; then
  ok "No alerts firing (healthy baseline)"
else
  warn "$firing alert(s) firing — expected DURING an incident, not at rest"
  # Show which ones (best-effort name extraction)
  echo "$rules" | tr '}' '\n' | grep -B0 '"state":"firing"' >/dev/null 2>&1
  names=$(echo "$rules" | grep -oE '"name":"[^"]+"|"state":"firing"' | paste - - 2>/dev/null | grep 'firing' | sed -nE 's/.*"name":"([^"]+)".*/    • \1/p')
  [ -n "$names" ] && echo -e "${YELLOW}$names${NC}"
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}pass: $PASS${NC}   ${YELLOW}warn: $WARN${NC}   ${RED}fail: $FAIL${NC}"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}✓ READY TO DEMO${NC} — the four signals + map + alerting are wired."
  [ "$WARN" -gt 0 ] && echo -e "  ${YELLOW}(warnings are usually 'needs a bit more traffic' — run ./traffic.sh)${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
  exit 0
else
  echo -e "  ${RED}✗ NOT READY${NC} — fix the ✗ items above, then re-run ./check.sh."
  echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
  exit 1
fi
