# Security Policy

## Scope: this is a demo

This repository is a **local evaluation demo**, not a production deployment.
It intentionally ships with choices that would be findings in a production
audit, so they are documented here rather than reported:

- **Known demo credentials**: Grafana admin password (`Mikroways123`) is
  hard-coded in `kind/values/grafana.yaml` and printed by `setup.sh`. The
  stack only listens on `127.0.0.1` (Kind port mappings) via `nip.io` names.
- **No TLS** between components and no SSO — see
  [docs/PRODUCTION.md](docs/PRODUCTION.md) for the hardening required before
  any real deployment (TLS everywhere, OIDC, NetworkPolicies, secrets
  management).
- The **Beyla sidecar (opt-in)** runs privileged by necessity (eBPF).

Please do not open security reports for the items above.

## Reporting a vulnerability

If you find a real vulnerability — e.g. in the demo services' code, the build
pipeline, or a configuration that would leak data beyond the local machine —
please report it privately:

1. Preferred: open a **GitHub Security Advisory** (Security → Report a
   vulnerability) on this repository.
2. Alternatively, email the maintainer listed on the repository profile.

You can expect an acknowledgement within a few business days. Please include
reproduction steps and affected files.

## Dependency updates

Dependencies (charts, images, language packages, pinned agents) are kept
current via [Renovate](renovate.json). Security fixes in dependencies are
applied by merging those PRs; the demo pins versions everywhere so updates
are always explicit and reviewable.
