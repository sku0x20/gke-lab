# Self-managed

Plan for taking over what GKE runs for us, one layer at a time. Nothing here is done yet.

| Stage | Cluster | We own |
|---|---|---|
| 1. Now | GKE Autopilot | workloads only |
| 2. Self-managed nodes | GKE Standard | + node pools |
| 3. Fully self-managed | Compute Engine VMs + kubeadm | + control plane and add-ons |

## Autopilot: what it does for us

Things seen on the live cluster that we'd have to handle ourselves later:

- **Nodes.** GKE picks the machine type (`ek-standard-8`), count and zones. Ours got 2 nodes in different zones, both created within a minute of the first valkey deploy. Likely reason for the second: system pods (kube-dns, konnectivity-agent) run 2 replicas spread across nodes. Unconfirmed.
- **Spare capacity.** Each node runs a `gke-system-balloon-pod` that requests the node's unused CPU and memory. GKE uses it to hold that capacity, and it makes way when real pods need room. Nodes look 99% full because of it.
- **Resource defaults.** A webhook rewrites pod specs: it adds `ephemeral-storage: 1Gi` (request and limit) when it's missing. CPU stays without a limit, so pods can burst into idle node CPU. The running pod and the manifest differ.
- **Billing.** Per pod request, not per node. System pods and balloon pods are free.
- **System pods.** Dataplane V2 (`anetd`, Cilium-based), `netd`, `ip-masq-agent`, `node-local-dns`, `gke-metadata-server` (Workload Identity), CSI node drivers (PD, Filestore, GCS FUSE, Secrets Store), log and metrics agents, kube-dns, metrics-server.

## Stage 2: self-managed nodes (GKE Standard)

Google still runs the control plane. We take over the nodes:

- Node pools: machine type, count, zones, autoscaling, Spot VMs.
- Upgrades: surge settings, maintenance windows.
- Billing per node VM. System pods now use capacity we pay for, so bin-packing matters.
- Resource defaults become ours (`LimitRange`, or set requests on every pod).
- Node SSH and privileged DaemonSets are allowed (node-exporter, debugging on the host).

## Stage 3: fully self-managed

Kubernetes on plain Compute Engine VMs. Everything GKE ran, we run:

- **Control plane:** API server, scheduler, controller-manager, etcd (backups, restores), certificates and their rotation, upgrades.
- **Networking:** a CNI plugin (Cilium or Calico), CoreDNS, kube-proxy (or a CNI-based replacement).
- **Cloud integration:** cloud-controller-manager for LoadBalancer Services, the PD CSI driver for disks, our own StorageClass in place of GKE's `standard-rwo`.
- **Identity:** no `gke-metadata-server`. Pods reach GCP through Workload Identity Federation, with the cluster's service-account issuer as the OIDC provider.
- **Secrets:** install the Secrets Store CSI driver and GCP provider ourselves in place of the add-on.
- **Access:** an API endpoint and auth in place of the DNS endpoint with IAM.

## What carries over

Most of `k8s/` should carry over unchanged. The parts tied to GKE:

- `storageClassName: standard-rwo`
- The SecretProviderClass's Workload Identity auth
- Any behaviour that only works because Autopilot injected defaults
