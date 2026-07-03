# Kind Cluster Configuration

This directory contains the Kubernetes-in-Docker (Kind) cluster configuration and Helm configuration for the demo environment.

## Structure

```
kind/
├── .kind/
│   └── config.yaml               # Kind cluster definition with port mappings
├── helmfile.d/
│   └── 04-grafana-stack.yaml     # All releases: ingress-nginx, Prometheus, Loki,
│                                 # Tempo, Grafana, Alloy (x2), Pyroscope, blackbox
├── values/                       # Custom Helm values per release
│   ├── alloy.yaml                # Alloy gateway: Faro receiver + OTLP pipeline
│   │                             # (k8sattributes, tail sampling, exemplars)
│   ├── alloy-logs.yaml           # Alloy DaemonSet: pod stdout log tailing -> Loki
│   ├── blackbox-exporter.yaml    # Synthetic / uptime probes
│   ├── grafana.yaml              # Datasources, Drilldown apps, provisioned alerts
│   ├── loki.yaml                 # SingleBinary + memcached
│   ├── prometheus.yaml           # Remote-write receiver, exemplars, SLO/Apdex rules
│   ├── pyroscope.yaml            # Continuous profiling backend
│   └── tempo.yaml                # Local storage + metrics generator (span metrics)
├── dashboards/                   # 16 Grafana dashboards as ConfigMaps
└── .kube/                        # Generated KUBECONFIG (auto-created)
```

## Configuration Files

### `.kind/config.yaml`
Defines the Kind cluster with:
- Single control-plane node
- Extra port mappings (80, 443) for Ingress access
- Kubernetes version 1.33.4

### `helmfile.d/04-grafana-stack.yaml`
Contains every Helm release deployed by `setup.sh`: the ingress controller,
the LGTM+P stack (Loki, Grafana, Tempo, Prometheus, Pyroscope), the blackbox
exporter for synthetic monitoring, and the two Grafana Alloy releases —
`alloy` (the OTLP/Faro gateway Deployment) and `alloy-logs` (the node log
collector DaemonSet).

## Usage

This directory is used automatically by `setup.sh`. Manual usage:

```bash
# Create cluster
kind create cluster --config kind/.kind/config.yaml --name grafana-otel-demo

# Set KUBECONFIG
export KUBECONFIG=$PWD/kind/.kube/config

# Apply Helmfiles
helmfile -f kind/helmfile.d/ apply

# (Re)apply the provisioned dashboards
kubectl apply -f kind/dashboards/
```

## Notes

- The `.kube/` directory is auto-generated and should not be committed
- Port mappings (80, 443) enable local access without port-forwarding
