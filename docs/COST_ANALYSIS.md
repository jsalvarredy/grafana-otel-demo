# Cost Analysis: SaaS vs Self-Hosted Observability

A realistic comparison of observability costs for mid-size deployments.

## Executive Summary

One reference scenario is used consistently throughout this document: **50
hosts, 100GB logs/month, APM on all hosts, 10-12 platform users**. Vendor
figures are public list prices (verify current pricing with the vendor).

| Solution | Annual Cost | Data Location |
|----------|-------------|---------------|
| Datadog | $36,000 list / $45,000-75,000 as typically billed | Datadog cloud |
| NewRelic | $35,000-60,000 (mostly user seats) | NewRelic cloud |
| Self-hosted (this stack) | $8,400 infrastructure + operations (see below) | Your infrastructure |

The honest summary: with an existing platform team absorbing operations,
self-hosted runs 60-80% cheaper in cash terms. If you must hire dedicated
operations for it, the math at 50 hosts is close to break-even — the
unambiguous wins are data control, retention on your terms, and a cost curve
that stays flat as you grow while vendor pricing scales linearly.

---

## Detailed Comparison

### Infrastructure Monitoring (50 Hosts)

| Vendor | Price Model | Monthly Cost | Annual Cost |
|--------|-------------|--------------|-------------|
| Datadog | $15/host/mo (Pro) | $750 | $9,000 |
| Datadog | $23/host/mo (Enterprise) | $1,150 | $13,800 |
| NewRelic | $0.25/GB ingested | Varies | $6,000-12,000 |
| Self-hosted | Prometheus | $0 licensing | $0 licensing |

### Log Management (100GB/month)

| Vendor | Price Model | Monthly Cost | Annual Cost |
|--------|-------------|--------------|-------------|
| Datadog | $0.10/GB ingested + $1.70/M indexed | ~$270 | ~$3,240 |
| NewRelic | $0.30/GB | $30 | $360 |
| Splunk | $150/GB/day indexed | ~$4,500 | ~$54,000 |
| Self-hosted | Loki | $0 licensing | $0 licensing |

### APM / Distributed Tracing (50 Hosts)

| Vendor | Price Model | Monthly Cost | Annual Cost |
|--------|-------------|--------------|-------------|
| Datadog | $31/host/mo | $1,550 | $18,600 |
| NewRelic | Included with Pro | - | - |
| Dynatrace | ~$69/host/mo | $3,450 | $41,400 |
| Self-hosted | Tempo | $0 licensing | $0 licensing |

### Adding It Up

**Datadog** (Enterprise infra $13,800 + logs $3,240 + APM $18,600) comes to
**~$35,600/year at list price**. Typical bills land higher — $45,000-75,000 —
once RUM, synthetic monitoring, custom metrics and ingest overages are added;
those SKUs are billed separately and are where most Datadog invoice surprises
come from.

**NewRelic** prices by data + user seats, not hosts — and seats dominate:

| Item | Price Model | Annual Cost |
|------|-------------|-------------|
| Data ingest (~200GB/mo total telemetry) | $0.30-0.35/GB | ~$840 |
| Full-platform users (10-12, Pro tier) | ~$349/user/mo list | $42,000-50,000 |
| **Total** | | **~$43,000-51,000** |

The $35,000-60,000 range in the summary covers 8-14 full-platform users.
The per-GB tables above understate NewRelic if you ignore seats.

### Data Retention

| Vendor | Default Retention | Extended Retention |
|--------|-------------------|-------------------|
| Datadog | 15 days | $$$$ |
| NewRelic | 8 days | $1.50/GB/month |
| This Stack | You decide — bounded by your storage | Object storage, ~$0.02/GB/month |

> Note: this demo ships with 15-day metrics retention and ephemeral
> trace/profile storage. Long retention in production requires object storage
> (S3/GCS/MinIO) behind Loki/Tempo/Pyroscope — see
> [PRODUCTION.md](PRODUCTION.md). "As long as you want" is an architectural
> property of the stack, not something the demo configures for you.

---

## Self-Hosted Costs

### Infrastructure (AWS Example)

Minimum footprint (single instance per component, no HA) supporting 50
monitored hosts:

| Component | Instance | Monthly Cost |
|-----------|----------|--------------|
| Prometheus | m5.large (2 vCPU, 8GB) | $70 |
| Loki | m5.xlarge (4 vCPU, 16GB) | $140 |
| Tempo | m5.large (2 vCPU, 8GB) | $70 |
| Grafana | t3.medium (2 vCPU, 4GB) | $30 |
| Storage (500GB SSD) | gp3 | $40 |
| **Total (minimum, no HA)** | | **$350/month ($4,200/year)** |

A production-grade deployment with replicas, multi-AZ placement and object
storage for long retention (what [PRODUCTION.md](PRODUCTION.md) actually
describes) roughly doubles this: **~$700/month ($8,400/year)**. The TCO
figures below use the production-grade number.

### Operational Costs

| Item | Estimate |
|------|----------|
| Initial setup | 40-80 hours |
| Ongoing maintenance | 2-4 hours/week |
| Training | 16-40 hours |

Labor is the dominant self-hosted cost and depends entirely on your starting
point:

- **Existing platform/SRE team**: steady-state operation is 2-4 hours/week —
  roughly **0.1-0.2 FTE of marginal effort** absorbed by a team you already
  pay. This is the typical on-premise adopter profile.
- **No platform team**: budget **0.5-1 dedicated FTE** — and read the TCO
  below before deciding, because at 50 hosts a dedicated hire erases the cash
  savings. The case then rests on scale, data sovereignty and retention, not
  on the invoice.

---

## Total Cost of Ownership (3 Years)

### 50 Hosts, 100GB Logs/Month, Full APM

Assumptions: setup one-off $20,000 (80-160 loaded hours); production-grade
infrastructure $8,400/year; dedicated operations, where imputed, at 0.2 FTE ≈
$2,000/month ($120k/year loaded cost — adjust to your market).

| Solution | Year 1 | Year 2 | Year 3 | Total |
|----------|--------|--------|--------|-------|
| Datadog Enterprise (list price) | $35,600 | $35,600 | $35,600 | ~$107,000 |
| Datadog (typical bill: RUM, synthetics, custom metrics, overages) | | | | $135,000-225,000 |
| NewRelic Pro (12 full-platform users + data) | $48,000 | $48,000 | $48,000 | $144,000 |
| Self-hosted — cash, existing platform team | $28,400 | $8,400 | $8,400 | **~$45,000** |
| Self-hosted — imputing 0.2 FTE dedicated ops | $52,400 | $32,400 | $32,400 | ~$117,000 |

*Self-hosted Year 1 includes the $20,000 setup.*

The honest read: at 50 hosts, self-hosted wins decisively on cash when an
existing platform team absorbs operations, and roughly breaks even against
Datadog's **list** price if you impute a dedicated 0.2 FTE. Two things move
the math further in self-hosted's favor: real vendor bills (typically above
list once add-ons land), and scale — vendor pricing grows linearly with hosts
and gigabytes, while your infrastructure and labor grow far slower.

---

## Hidden Costs of SaaS

### Vendor Lock-in

- Custom dashboards tied to vendor
- Alert rules in proprietary format
- Team trained on vendor-specific tools
- Migration cost: 3-6 months effort

### Data Egress

- Your telemetry data leaves your network
- Compliance implications (GDPR, HIPAA, SOC2)
- No control over data retention or access

### Price Increases

- SaaS vendors typically raise prices 5-15% annually
- Volume discounts decrease as you scale
- New features often require higher tiers

---

## Hidden Costs of Self-Hosted

### Expertise Required

- Kubernetes administration
- Observability stack tuning
- Capacity planning
- Incident response for the monitoring system itself

### Ongoing Maintenance

- Version upgrades
- Security patches
- Storage management
- Performance optimization

### Opportunity Cost

- Team time spent on infrastructure vs product

---

## When SaaS Makes Sense

- Teams <10 engineers with no DevOps/SRE capacity
- Startups prioritizing speed over cost
- Short-term projects (<1 year)
- Organizations with no Kubernetes experience

## When Self-Hosted Makes Sense

- 50+ monitored hosts **with an existing platform team** (150+ if you would
  need to hire for it)
- Data sovereignty requirements
- Compliance restrictions (data must stay on-premise)
- Long-term cost optimization priority
- Existing Kubernetes and DevOps expertise
- High log/metric volume (>100GB/month)

---

## ROI Calculator

Both scenarios use the same reference case and assumptions as the TCO table.

### Scenario A — existing platform team (ops absorbed as marginal work)

```
Monthly SaaS cost (Datadog list):     $3,000
Monthly self-hosted cash cost:        $700 (infrastructure)
Monthly savings:                      $2,300
Initial setup cost:                   $20,000

Break-even: 20,000 / 2,300 ≈ 9 months
3-year: $107,000 (SaaS) vs $45,000 (self-hosted) → $62,000 saved (58%)
```

### Scenario B — dedicated 0.2 FTE imputed

```
Monthly self-hosted cost:             $700 + $2,000 (labor) = $2,700
Monthly savings vs Datadog list:      $300

At this scale the setup cost never meaningfully pays back. Break-even
arrives via scale (150+ hosts), high log volume, or comparing against
typical billed amounts ($45,000-75,000/year) rather than list price.
```

---

## Next Steps

1. **Evaluate this demo** - See the stack in action
2. **Estimate your volume** - Hosts, logs/month, traces/day
3. **Calculate your costs** - Use numbers above as baseline
4. **Plan migration** - Start with non-critical workloads

