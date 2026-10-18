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

### mongod connection noise

mongod logs every connection: TLS handshake, auth, disconnect. The probes (exec healthcheck, every few seconds) and the operator (reconciles every 5s) open new connections all the time. Measured on the idle 3-member replica set: ~1,800 lines/min, ~25 MB/hour, ~20 GB/month if left up 24/7. The top messages:

| Lines/min, rs0-0 | `jsonPayload.msg` |
|---|---|
| 165 | `Ingress TLS handshake complete` |
| 165 | `Client connecting with server's own TLS certificate` |
| 110 | `Connection not authenticating` |
| 55 each | `Auth metrics report`, `Successfully authenticated`, `Received first command on ingress connection since session start or auth handshake`, `Interrupted operation as its client disconnected` |

Drop them at ingestion with a project exclusion: never billed, and `kubectl logs` still shows everything. It's project-level, not tied to the cluster, so it goes in `infra/static`:

```hcl
# mongod per-connection lines from probes and the operator; excluded logs are not billed
resource "google_logging_project_exclusion" "mongod_connection_noise" {
  name   = "mongod-connection-noise"
  filter = <<-EOT
    resource.type="k8s_container"
    resource.labels.namespace_name="mongo"
    resource.labels.container_name="mongod"
    jsonPayload.msg=("Ingress TLS handshake complete" OR
      "Client connecting with server's own TLS certificate" OR
      "Connection not authenticating" OR
      "Auth metrics report" OR
      "Successfully authenticated" OR
      "Received first command on ingress connection since session start or auth handshake" OR
      "Interrupted operation as its client disconnected")
  EOT
}
```

Match on `msg`, not on the component (`jsonPayload.c="ACCESS"`): that would also drop `Failed to authenticate`, which is the line worth keeping. Before applying, paste the filter into Logs Explorer (Logging → Logs Explorer) and check it matches only these lines; GKE parsing mongod's JSON into `jsonPayload` is unconfirmed.

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

## Pod requests

Autopilot bills each pod's requests (vCPU, memory, ephemeral storage) for as long as it runs. Actual usage doesn't count, and neither does bursting above the request into idle node CPU. Oversized requests are the waste.

valkey at idle: 19m CPU used of 250m requested, 5Mi memory of 512Mi (empty dataset).

### Plan

1. Measure under real load, not idle: `kubectl top pod -A --containers`, or `%CPU/R` and `%MEM/R` in k9s.
2. CPU: lower the request toward real usage plus headroom. With no CPU limit the pod still bursts when the node has idle CPU. Under contention it only gets its request's share.
3. Memory: keep request = limit, sized to what the app must hold. For valkey that's `maxmemory` plus overhead, so lowering one means lowering the other.
4. Ephemeral storage: Autopilot adds a 1Gi request when none is set. Set a smaller one explicitly if the app writes little to its own filesystem.
5. Autopilot enforces minimum requests and allowed CPU:memory ratios, and raises requests to fit (exact values unconfirmed). After a deploy, the `autopilot.gke.io/resource-adjustment` annotation shows what it changed.

### Spot Pods

The same requests, billed at a steep Spot discount. GKE can preempt the pod at any time with a short warning. A good fit for a lab that gets destroyed every session anyway. In the pod template (`spec.template.spec`):

```yaml
      # Spot pricing; GKE can preempt the pod at any time
      nodeSelector:
        cloud.google.com/gke-spot: "true"
```

Caveats for valkey:

- A preemption restarts it, and it reloads the AOF. With `appendfsync everysec`, the last second of writes can be lost.
- The PVC's disk is zonal, so the replacement pod has to run in that same zone. If there's no Spot capacity there, it stays `Pending`.
- The node size still doesn't matter for cost. Spot changes the price per request, nothing else.

## Other defaults

Locked by Autopilot, no direct cost: Dataplane V2, Workload Identity, Shielded Nodes, VPA, NodeLocal DNSCache, Cloud DNS, image streaming, CSI drivers (pay only for volumes).

Free until used: Gateway API (a Gateway creates an LB), security posture `BASIC`, intranode visibility (costs only with subnet flow logs on).
