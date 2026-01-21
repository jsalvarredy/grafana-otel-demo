# Cost Analysis: SaaS vs Self-Hosted Observability

A realistic comparison of observability costs for mid-size deployments.

## Executive Summary

For a typical deployment (50 hosts, 100GB logs/month, standard APM):

| Solution | Annual Cost | Data Location |
|----------|-------------|---------------|
| Datadog | $45,000-75,000 | Datadog cloud |
| NewRelic | $35,000-60,000 | NewRelic cloud |
| Self-hosted (this stack) | $5,000-15,000 | Your infrastructure |

Self-hosted typically costs 70-85% less, with complete data control.

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

### Data Retention

| Vendor | Default Retention | Extended Retention |
|--------|-------------------|-------------------|
| Datadog | 15 days | $$$$ |
| NewRelic | 8 days | $1.50/GB/month |
| This Stack | Unlimited | Storage cost only |

---

## Self-Hosted Costs

### Infrastructure (AWS Example)

For a production-grade setup supporting 50 monitored hosts:

| Component | Instance | Monthly Cost |
|-----------|----------|--------------|
| Prometheus | m5.large (2 vCPU, 8GB) | $70 |
| Loki | m5.xlarge (4 vCPU, 16GB) | $140 |
| Tempo | m5.large (2 vCPU, 8GB) | $70 |
| Grafana | t3.medium (2 vCPU, 4GB) | $30 |
| Storage (500GB SSD) | gp3 | $40 |
| **Total Infrastructure** | | **$350/month** |
| **Annual Infrastructure** | | **$4,200** |

### Operational Costs

| Item | Estimate |
|------|----------|
| Initial setup | 40-80 hours |
| Ongoing maintenance | 2-4 hours/week |
| Training | 16-40 hours |

With internal team: factor 0.5-1 FTE for observability platform management.

With Mikroways support: reduced to ~0.1 FTE oversight.

---

## Total Cost of Ownership (3 Years)

### 50 Hosts, 100GB Logs/Month, Full APM

| Solution | Year 1 | Year 2 | Year 3 | Total |
|----------|--------|--------|--------|-------|
| Datadog Enterprise | $75,000 | $75,000 | $75,000 | $225,000 |
| NewRelic Pro | $48,000 | $48,000 | $48,000 | $144,000 |
| Self-hosted + Support | $25,000 | $15,000 | $15,000 | $55,000 |

*Self-hosted Year 1 includes setup and initial support.*

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

- 50+ monitored hosts
- Data sovereignty requirements
- Compliance restrictions (data must stay on-premise)
- Long-term cost optimization priority
- Existing Kubernetes and DevOps expertise
- High log/metric volume (>100GB/month)

---

## ROI Calculator

### Break-even Analysis

```
Monthly SaaS cost: $5,000
Monthly self-hosted cost: $500 (infrastructure) + $2,000 (labor) = $2,500
Monthly savings: $2,500
Initial setup cost: $20,000

Break-even: 20,000 / 2,500 = 8 months
```

### 3-Year ROI

```
SaaS 3-year cost: $180,000
Self-hosted 3-year cost: $20,000 (setup) + $90,000 (ongoing) = $110,000
Savings: $70,000
ROI: 64%
```

---

## Next Steps

1. **Evaluate this demo** - See the stack in action
2. **Estimate your volume** - Hosts, logs/month, traces/day
3. **Calculate your costs** - Use numbers above as baseline
4. **Plan migration** - Start with non-critical workloads

### Need a Custom Analysis?

Mikroways can provide a detailed cost analysis for your specific environment, including:

- Current SaaS spend analysis
- Infrastructure sizing for your workload
- Migration timeline and effort estimate
- Ongoing support options

Contact: https://mikroways.net/contacto/
