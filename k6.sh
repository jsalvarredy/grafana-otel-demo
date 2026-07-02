#!/usr/bin/env bash
# ============================================================================
# k6.sh - on-brand load testing for the demo with Grafana k6.
#
# Runs a k6 load test (k6/load.js) and streams the results to Prometheus via
# remote write, so you can watch them live on the "k6 Load Testing" dashboard
# in Grafana. Because the load hits the same instrumented services, it also
# drives the RED dashboards, traces and the service map.
#
# Default: runs IN-CLUSTER as a Kubernetes Job (no local k6 needed), targeting
# the demo service DNS and remote-writing to Prometheus.
#
# Usage:
#   ./k6.sh                      # 10 VUs: 30s ramp + 3m hold
#   ./k6.sh --vus 25 --hold 5m   # heavier / longer
#   ./k6.sh --logs               # follow the Job logs until it finishes
#   ./k6.sh --local              # run with a locally-installed k6 vs the ingress
#   ./k6.sh --stop               # delete the running Job
# ============================================================================
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'

K6_IMAGE="${K6_IMAGE:-grafana/k6:1.8.0}"
NS="${K6_NAMESPACE:-demo}"
PROM_RW="${K6_PROM_RW:-http://prometheus-server.monitoring.svc.cluster.local/api/v1/write}"
VUS=10; RAMP="30s"; HOLD="3m"; MODE="cluster"; FOLLOW=false; STOP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vus) VUS="${2:?}"; shift 2 ;;
    --ramp) RAMP="${2:?}"; shift 2 ;;
    --hold) HOLD="${2:?}"; shift 2 ;;
    --local) MODE="local"; shift ;;
    --logs) FOLLOW=true; shift ;;
    --stop) STOP=true; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_JS="${SCRIPT_DIR}/k6/load.js"
[[ -f "$LOAD_JS" ]] || { echo -e "${RED}Cannot find k6/load.js next to k6.sh${NC}"; exit 1; }

if [[ -z "${KUBECONFIG:-}" && -f "${SCRIPT_DIR}/kind/.kube/config" ]]; then
  export KUBECONFIG="${SCRIPT_DIR}/kind/.kube/config"
fi

# --------------------------------------------------------------------------
# Local mode: run against the ingress with a locally installed k6.
# --------------------------------------------------------------------------
if [[ "$MODE" == "local" ]]; then
  command -v k6 >/dev/null 2>&1 || { echo -e "${RED}k6 not installed locally. Install it or drop --local to run in-cluster.${NC}"; exit 1; }
  echo -e "${CYAN}Running k6 locally against the ingress (results in console)...${NC}"
  PRODUCTS_URL="http://products.127.0.0.1.nip.io" \
  ORDERS_URL="http://orders.127.0.0.1.nip.io" \
  SHIPPING_URL="http://shipping.127.0.0.1.nip.io" \
  VUS="$VUS" RAMP="$RAMP" HOLD="$HOLD" \
    k6 run "$LOAD_JS"
  exit $?
fi

# --------------------------------------------------------------------------
# Cluster mode (default).
# --------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}kubectl not found${NC}"; exit 1; }

if [[ "$STOP" == true ]]; then
  kubectl delete job k6-load -n "$NS" --ignore-not-found
  echo -e "${GREEN}✓ k6 Job stopped.${NC}"; exit 0
fi

echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  k6 load test (in-cluster) -> Prometheus remote write${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo -e "  Image:   ${BOLD}${K6_IMAGE}${NC}"
echo -e "  Load:    ${BOLD}${VUS} VUs${NC}, ramp ${RAMP}, hold ${HOLD}"
echo -e "  Metrics: ${BOLD}${PROM_RW}${NC}"
echo ""

# Ship the script as a ConfigMap (regenerated from k6/load.js each run).
kubectl create configmap k6-script -n "$NS" \
  --from-file=load.js="$LOAD_JS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# (Re)create the Job.
kubectl delete job k6-load -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: k6-load
  namespace: ${NS}
  labels: { app: k6-load }
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 900
  template:
    metadata:
      labels: { app: k6-load }
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: ${K6_IMAGE}
          command: ["sh", "-c"]
          # '|| true' so a breached threshold (expected during an incident)
          # doesn't leave the Job in a scary "Failed" state during the demo.
          args: ["k6 run --out experimental-prometheus-rw /scripts/load.js || true"]
          env:
            - { name: K6_PROMETHEUS_RW_SERVER_URL, value: "${PROM_RW}" }
            - { name: K6_PROMETHEUS_RW_TREND_STATS, value: "p(95),p(99),avg,max" }
            - { name: K6_PROMETHEUS_RW_PUSH_INTERVAL, value: "5s" }
            - { name: VUS,  value: "${VUS}" }
            - { name: RAMP, value: "${RAMP}" }
            - { name: HOLD, value: "${HOLD}" }
          volumeMounts:
            - { name: script, mountPath: /scripts }
      volumes:
        - name: script
          configMap: { name: k6-script }
EOF

echo -e "${GREEN}✓ k6 Job launched.${NC} Watch the ${BOLD}k6 Load Testing${NC} dashboard in Grafana"
echo -e "  (${CYAN}/d/k6-load-testing${NC}), or the RED / Service Map dashboards."
echo ""
echo -e "  Logs:  ${CYAN}kubectl logs -f job/k6-load -n ${NS}${NC}"
echo -e "  Stop:  ${CYAN}./k6.sh --stop${NC}"

if [[ "$FOLLOW" == true ]]; then
  echo ""; echo -e "${CYAN}── following k6 logs ──${NC}"
  kubectl wait --for=condition=ready pod -l app=k6-load -n "$NS" --timeout=60s >/dev/null 2>&1 || true
  kubectl logs -f job/k6-load -n "$NS" 2>/dev/null || true
fi
