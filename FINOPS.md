# FinOps

Cost notes and pending cuts. Nothing here is applied yet.

## Observability

Autopilot turns most of this on by default. Check what's live:

```sh
gcloud container clusters describe lab --region asia-south1 \
  --format="yaml(loggingConfig,monitoringConfig)"
```

### Metrics

| Package | Default | Off on Autopilot? | Cost |
|---|---|---|---|
| `SYSTEM_COMPONENTS` | on | no, required | free |
| Kube state: `POD` `DEPLOYMENT` `STATEFULSET` `DAEMONSET` `HPA` `JOBSET` `STORAGE` | on | yes | per sample |
| `CADVISOR`, `KUBELET` | on | yes | per sample, the big one (many series per container) |
| `DCGM` | on | yes | none without GPU pods |
| Control plane: `API_SERVER` `SCHEDULER` `CONTROLLER_MANAGER` | off | n/a | per sample |
| Dataplane V2 metrics | on | yes | unconfirmed; check Metrics management |

Paid packages cost $0.06 per million samples. One series scraped every 30s is about 86k samples/month, roughly $0.005. cAdvisor/kubelet across a few nodes runs to thousands of series, which can mean tens of dollars a month if the cluster stays up.

### Logs

`SYSTEM_COMPONENTS` is required. `WORKLOADS` (container stdout/stderr) is optional. Ingestion is about $0.50/GiB after roughly 50 GiB/month free, kept 30 days (unconfirmed). Only worth cutting if an app logs heavily.

### Plan

1. Measure first. Console: Monitoring → Metrics management (sort by billable samples), and Billing → Reports (filter service: Cloud Monitoring).
2. Trim in tofu, not gcloud, so state doesn't drift. In `google_container_cluster.lab`:

```hcl
  # system metrics are free; the other packages are billed per sample ingested
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "POD", "DEPLOYMENT"]
    managed_prometheus {
      enabled = true
    }
  }
```

`tofu plan` should list only the packages being removed.

### In-cluster alternative

Self-hosted Prometheus/Grafana isn't free on Autopilot: you pay for those pods' CPU, memory and disk. Autopilot also blocks privileged DaemonSets like node-exporter. It only pays off for a 24/7 cluster with lots of series, or for learning the stack itself.

## Other defaults

Locked by Autopilot, no direct cost: Dataplane V2, Workload Identity, Shielded Nodes, VPA, NodeLocal DNSCache, Cloud DNS, image streaming, CSI drivers (pay only for volumes).

Free until used: Gateway API (a Gateway creates an LB), security posture `BASIC`, intranode visibility (costs only with subnet flow logs on).
