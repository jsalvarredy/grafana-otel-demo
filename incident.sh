#!/usr/bin/env bash
#
# incident.sh - Live incident injector for the Grafana observability demo.
# ---------------------------------------------------------------------------
# Drives a controlled, *sustained* degradation against the demo services so a
# live audience can watch the full story unfold in Grafana:
#
#   1. Error rate / latency climb on the Service Overview (RED) dashboard.
#   2. The provisioned alerts move pending -> firing (~2-5 min, see `for:`).
#   3. The SLO dashboard shows the error budget burning down.
#   4. A latency exemplar / an error span jumps you straight to a trace, then
#      from the trace to the logs (and, in Sprint 1, to the flame graph).
#
# It always keeps a stream of *healthy* background traffic running too, so the
# error ratio and percentiles look like a real partial outage, not a flatline.
#
# By default it targets Products (Node) and Orders (Python): their real
# cross-service call (orders -> products) makes the most illustrative trace.
# Shipping (Java) is auto-instrumented by the OTel Java agent (any kernel) and
# can be added to the blast radius with --include-shipping.
#
# Usage:
#   ./incident.sh                         # meltdown (errors+latency), 7 min
#   ./incident.sh -s errors -d 600        # only 5xx errors, 10 min
#   ./incident.sh -s latency              # only high latency
#   ./incident.sh -t products             # hit a single service
#   ./incident.sh --include-shipping      # also hammer Java/Beyla endpoints
#   ./incident.sh --recover               # healthy-only traffic (clear alerts)
#
# Requires: curl. No cluster access needed - traffic goes through the ingress
# on localhost using the Host header, exactly like setup.sh / traffic.sh.

set -euo pipefail

# --------------------------------------------------------------------------
# Colors
# --------------------------------------------------------------------------
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------
SCENARIO="meltdown"        # latency | errors | meltdown
TARGET="all"               # products | orders | all
DURATION=420               # seconds (> alert `for:` so alerts actually fire)
RECOVER=false
INCLUDE_SHIPPING=false
FORCE=false
BASE_URL="http://localhost"

GRAFANA="${GRAFANA:-http://grafana.127.0.0.1.nip.io}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASS="${GRAFANA_PASS:-Mikroways123}"
PRODUCTS_HOST="products.127.0.0.1.nip.io"
ORDERS_HOST="orders.127.0.0.1.nip.io"
SHIPPING_HOST="shipping.127.0.0.1.nip.io"

# Tunables (workers running concurrently per phase)
HEALTHY_WORKERS=2
ERROR_WORKERS=3
LATENCY_WORKERS=6
SLOW_DELAY_MS=1500         # per slow request; >> 500ms P95 threshold

usage() {
  cat <<EOF
${BOLD}incident.sh${NC} - Live incident injector for the Grafana observability demo

${BOLD}Options:${NC}
  -s, --scenario <name>   latency | errors | meltdown   (default: meltdown)
  -t, --target <name>     products | orders | all        (default: all)
  -d, --duration <secs>   how long to sustain the incident (default: 420)
      --include-shipping  also hit Shipping (Java, OTel Java agent)
  -r, --recover           send only healthy traffic to let alerts clear
      --force             run even if the preflight health check fails
  -h, --help              show this help

${BOLD}Examples:${NC}
  ./incident.sh                      # full meltdown for 7 minutes
  ./incident.sh -s errors -d 600     # error spike for 10 minutes
  ./incident.sh --recover -d 300     # recovery phase for 5 minutes
EOF
}

# --------------------------------------------------------------------------
# Arg parsing
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--scenario) SCENARIO="${2:-}"; shift 2 ;;
    -t|--target) TARGET="${2:-}"; shift 2 ;;
    -d|--duration) DURATION="${2:-}"; shift 2 ;;
    --include-shipping) INCLUDE_SHIPPING=true; shift ;;
    -r|--recover) RECOVER=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo -e "${RED}Unknown option: $1${NC}" >&2; usage; exit 1 ;;
  esac
done

case "$SCENARIO" in latency|errors|meltdown) ;; *)
  echo -e "${RED}Invalid --scenario '$SCENARIO' (use latency|errors|meltdown)${NC}" >&2; exit 1 ;;
esac
case "$TARGET" in products|orders|all) ;; *)
  echo -e "${RED}Invalid --target '$TARGET' (use products|orders|all)${NC}" >&2; exit 1 ;;
esac
if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -lt 1 ]]; then
  echo -e "${RED}--duration must be a positive integer (seconds)${NC}" >&2; exit 1
fi

# --------------------------------------------------------------------------
# HTTP helper - all traffic goes through the ingress with a Host header.
# --------------------------------------------------------------------------
req() {
  local host="$1" path="$2" method="${3:-GET}" data="${4:-}"
  if [[ "$method" == "POST" ]]; then
    curl -s -o /dev/null -m 12 -X POST \
      -H "Host: $host" -H "Content-Type: application/json" \
      -d "$data" "${BASE_URL}${path}" 2>/dev/null || true
  else
    curl -s -o /dev/null -m 12 -H "Host: $host" "${BASE_URL}${path}" 2>/dev/null || true
  fi
}

# --------------------------------------------------------------------------
# Grafana annotation - draws incident/recovery context on every dashboard.
# Real releases are emitted exclusively by setup.sh / deploy-observe.sh.
# Point annotation if no end time is given, region if one is. Best-effort;
# never aborts the run. Dashboards expose separate Deployments, Incidents and
# Recoveries toggles (tags: deployment / incident / recovery).
# --------------------------------------------------------------------------
grafana_annotation() {
  local text="$1" tags_csv="$2" time_ms="$3" end_ms="${4:-}"
  local tags_json="[" first=1 t
  local IFS=','
  for t in $tags_csv; do
    [[ $first -eq 0 ]] && tags_json+=","
    tags_json+="\"$t\""; first=0
  done
  tags_json+="]"
  local body="{\"time\":${time_ms}"
  [[ -n "$end_ms" ]] && body+=",\"timeEnd\":${end_ms}"
  body+=",\"tags\":${tags_json},\"text\":\"${text}\"}"
  local resp
  resp=$(curl -s -m 8 -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
    -H "Content-Type: application/json" -X POST \
    -d "$body" "${GRAFANA}/api/annotations" 2>/dev/null) || true
  if [[ "$resp" == *'"id"'* ]]; then
    echo -e "  ${GREEN}✓${NC} Grafana annotation created: ${BOLD}${text}${NC}"
  else
    echo -e "  ${YELLOW}⚠${NC}  could not create Grafana annotation (is Grafana reachable / auth ok?)"
  fi
}

# Resolve which services are in scope for error/latency injection.
targets=()
[[ "$TARGET" == "products" || "$TARGET" == "all" ]] && targets+=("products")
[[ "$TARGET" == "orders"   || "$TARGET" == "all" ]] && targets+=("orders")
[[ "$INCLUDE_SHIPPING" == true ]] && targets+=("shipping")

# --------------------------------------------------------------------------
# Preflight: make sure the stack is reachable before we pretend to break it.
# --------------------------------------------------------------------------
preflight() {
  local code
  code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' \
    -H "Host: $PRODUCTS_HOST" "${BASE_URL}/health" 2>/dev/null) || true
  [[ -z "$code" ]] && code="000"
  if [[ "$code" != "200" && "$code" != "503" ]]; then
    echo -e "${RED}✗ Products service did not respond at ${BASE_URL} (Host: ${PRODUCTS_HOST}).${NC}"
    echo -e "${YELLOW}  Is the demo up? Try ./setup.sh first. Got HTTP '${code}'.${NC}"
    if [[ "$FORCE" != true ]]; then
      echo -e "${YELLOW}  Re-run with --force to inject anyway.${NC}"
      exit 1
    fi
  else
    echo -e "${GREEN}✓ Stack reachable (Products /health -> HTTP ${code}).${NC}"
  fi
}

# --------------------------------------------------------------------------
# Workers. Each loops until the shared deadline END_TS, then exits.
# --------------------------------------------------------------------------
healthy_worker() {
  while [[ "$(date +%s)" -lt "$END_TS" ]]; do
    local pid=$(( RANDOM % 8 + 1 ))
    req "$PRODUCTS_HOST" "/api/products"
    req "$PRODUCTS_HOST" "/api/products/${pid}"
    req "$PRODUCTS_HOST" "/api/categories"
    req "$ORDERS_HOST"   "/api/orders" "POST" \
      "{\"product_id\": ${pid}, \"quantity\": 1, \"user_id\": \"user-$(( RANDOM % 20 + 1 ))\"}"
    sleep 0.3
  done
}

error_worker() {
  while [[ "$(date +%s)" -lt "$END_TS" ]]; do
    for svc in "${targets[@]}"; do
      case "$svc" in
        products) req "$PRODUCTS_HOST" "/error" ;;
        orders)   req "$ORDERS_HOST"   "/error" ;;
        shipping) req "$SHIPPING_HOST" "/api/error" ;;
      esac
    done
    sleep 0.1
  done
}

latency_worker() {
  while [[ "$(date +%s)" -lt "$END_TS" ]]; do
    for svc in "${targets[@]}"; do
      case "$svc" in
        products) req "$PRODUCTS_HOST" "/api/slow?delay=${SLOW_DELAY_MS}" ;;
        orders)   req "$ORDERS_HOST"   "/api/slow?delay=${SLOW_DELAY_MS}" ;;
        shipping) req "$SHIPPING_HOST" "/api/slow" ;;
      esac
    done
  done
}

# --------------------------------------------------------------------------
# Cleanup: kill all background workers on exit / Ctrl+C.
# --------------------------------------------------------------------------
PIDS=()
cleanup() {
  trap - INT TERM EXIT
  echo ""
  echo -e "${YELLOW}▶ Stopping incident injection...${NC}"
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  if [[ "$RECOVER" != true ]]; then
    local actual_end_ms=$(( $(date +%s) * 1000 ))
    grafana_annotation "Incident simulation: ${SCENARIO} on ${targets[*]}" \
      "incident,simulation,scenario:${SCENARIO}" "$INCIDENT_START_MS" "$actual_end_ms"
    echo -e "${CYAN}Tip:${NC} run ${BOLD}./incident.sh --recover${NC} to send healthy-only"
    echo -e "      traffic and watch the alerts resolve back to OK."
  fi
  echo -e "${GREEN}✓ Done.${NC}"
}

# --------------------------------------------------------------------------
# Banner
# --------------------------------------------------------------------------
mins=$(( DURATION / 60 )); secs=$(( DURATION % 60 ))
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
if [[ "$RECOVER" == true ]]; then
  echo -e "${CYAN}  Grafana Demo - RECOVERY phase${NC}"
else
  echo -e "${CYAN}  Grafana Demo - INCIDENT injector${NC}"
fi
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
preflight
if [[ "$RECOVER" == true ]]; then
  echo -e "  Mode:      ${GREEN}recovery${NC} (healthy traffic only)"
else
  echo -e "  Scenario:  ${BOLD}${SCENARIO}${NC}"
  echo -e "  Targets:   ${BOLD}${targets[*]}${NC}"
fi
echo -e "  Duration:  ${BOLD}${mins}m ${secs}s${NC}"
echo ""

END_TS=$(( $(date +%s) + DURATION ))

# --------------------------------------------------------------------------
# Tell the story on the dashboards with semantically honest annotations.
# This script injects traffic only: it never claims that a real deploy/rollback
# happened. Real releases are recorded by setup.sh / deploy-observe.sh.
# --------------------------------------------------------------------------
NOW_MS=$(( $(date +%s) * 1000 ))
INCIDENT_START_MS="$NOW_MS"
if [[ "$RECOVER" == true ]]; then
  grafana_annotation "Recovery traffic started after incident simulation" "recovery,simulation" "$NOW_MS"
else
  # Point marker is visible immediately. cleanup() adds the real-duration region
  # when the run finishes or is interrupted.
  grafana_annotation "Incident simulation started: ${SCENARIO} on ${targets[*]}" \
    "incident,simulation,scenario:${SCENARIO}" "$NOW_MS"
fi
echo ""

# Arm cleanup now that we are about to spawn background workers.
on_signal() {
  local exit_code="$1"
  cleanup
  exit "$exit_code"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap cleanup EXIT

# --------------------------------------------------------------------------
# Launch workers
# --------------------------------------------------------------------------
# Healthy background traffic always runs (gives a realistic denominator).
for _ in $(seq 1 "$HEALTHY_WORKERS"); do healthy_worker & PIDS+=("$!"); done

if [[ "$RECOVER" != true ]]; then
  if [[ "$SCENARIO" == "errors" || "$SCENARIO" == "meltdown" ]]; then
    for _ in $(seq 1 "$ERROR_WORKERS"); do error_worker & PIDS+=("$!"); done
  fi
  if [[ "$SCENARIO" == "latency" || "$SCENARIO" == "meltdown" ]]; then
    for _ in $(seq 1 "$LATENCY_WORKERS"); do latency_worker & PIDS+=("$!"); done
  fi
fi

# --------------------------------------------------------------------------
# What to watch (the demo script)
# --------------------------------------------------------------------------
if [[ "$RECOVER" == true ]]; then
  echo -e "${GREEN}Sending healthy traffic. Within a few minutes the firing alerts"
  echo -e "should clear and the SLO error budget stops burning.${NC}"
else
  echo -e "${BOLD}While this runs, narrate the incident in Grafana:${NC}"
  echo -e "  ${BLUE}1.${NC} Alerts firing:   ${CYAN}${GRAFANA}/alerting/list${NC}"
  echo -e "       (pending -> firing after the rule's ${YELLOW}for:${NC} window, ~2-5 min)"
  echo -e "  ${BLUE}2.${NC} RED metrics:     ${CYAN}${GRAFANA}/d/otel-service-overview${NC}"
  echo -e "       watch Error rate and P95 latency climb per service"
  echo -e "  ${BLUE}3.${NC} Error budget:    ${CYAN}${GRAFANA}/d/slo-sli-error-budget-v1${NC}"
  echo -e "  ${BLUE}4.${NC} Metric->trace:   on a latency panel, click an ${BOLD}exemplar${NC} dot"
  echo -e "       -> opens the exact slow/errored trace in Tempo"
  echo -e "  ${BLUE}5.${NC} Trace->logs:     in the trace, use ${BOLD}Logs for this span${NC}"
  echo -e "  ${BLUE}6.${NC} Queryless:       explore it all under ${BOLD}Drilldown${NC} in the nav"
fi
echo ""

# --------------------------------------------------------------------------
# Progress bar until the deadline
# --------------------------------------------------------------------------
while [[ "$(date +%s)" -lt "$END_TS" ]]; do
  now=$(date +%s)
  remaining=$(( END_TS - now ))
  elapsed=$(( DURATION - remaining ))
  printf "\r  ${BLUE}▶${NC} injecting... %3ds elapsed / %3ds left  " "$elapsed" "$remaining"
  sleep 2
done

echo ""
# cleanup runs via trap on EXIT
