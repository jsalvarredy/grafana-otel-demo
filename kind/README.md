# Kind Cluster Configuration

This directory contains the Kubernetes-in-Docker (Kind) cluster configuration and Helm configuration for the demo environment.

## Structure

```
kind/
├── .kind/
│   └── config.yaml           # Kind cluster definition with port mappings
├── helmfile.d/               # Helm chart configurations
│   ├── 04-grafana-stack.yaml # Grafana Stack (Loki, Tempo, Prometheus, Grafana)
│   └── values/               # Custom Helm values
│       ├── grafana.yaml
│       ├── loki.yaml
│       ├── prometheus.yaml
│       ├── otel-collector.yaml
│       └── tempo.yaml
└── .kube/                    # Generated KUBECONFIG (auto-created)
```

## Configuration Files

### `.kind/config.yaml`
Defines the Kind cluster with:
- Single control-plane node
- Extra port mappings (80, 443) for Ingress access
- Kubernetes version 1.33.4

### `/helmfile.d/`
Contains Helmfile definitions deployed by `setup.sh`:
- **Grafana Stack**: Complete observability stack components

## Usage

This directory is used automatically by `setup.sh`. Manual usage:

```bash
# Create cluster
kind create cluster --config kind/.kind/config.yaml --name grafana-otel-demo

# Set KUBECONFIG
export KUBECONFIG=$PWD/kind/.kube/config

# Apply Helmfiles
helmfile -f kind/helmfile.d/ apply
```

## Notes

- The `.kube/` directory is auto-generated and should not be committed
- Port mappings (80, 443) enable local access without port-forwarding
