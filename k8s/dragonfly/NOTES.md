# Dragonfly FAQ

Dragonfly (Redis-compatible), run by the Dragonfly operator.

## Basics

### What gets deployed?

Two kapp apps:

- `dragonfly-operator`: the CRD, RBAC, the operator Deployment, and the `dragonfly-operator-system` namespace.
- `dragonfly`: one `Dragonfly` resource (not written yet). The operator creates the StatefulSet, Services and PDB.

### Why Dragonfly next to valkey?

For failover and upgrades without downtime. The operator promotes a replica when the master dies and rolls replicas before the master. Valkey stays as it is: a single plain StatefulSet.

### Why not a Valkey operator?

None is ready. The official one (valkey-io, v0.8) is pre-production, cluster mode only (sharded, cluster-aware clients), and has no bucket backups. Percona contributes to it rather than shipping its own. The community operators are small.

### Why an operator and not Sentinel?

Sentinel only promotes. It doesn't know about Kubernetes: a Service can't follow the master, and a StatefulSet rollout doesn't know which pod is master. We'd script both. The operator does both.

### What does the operator not do?

- No backup or restore resources, no snapshot retention, no PITR.
- Snapshots only, no AOF: writes since the last snapshot are lost if every pod goes down.
- Replication is async: a failover can lose the last writes.
- No sharding (cluster mode).
- `v1alpha1` API: fields can change between releases.

### In what order do I deploy and destroy?

Deploy `dragonfly-operator`, then `dragonfly`. Destroy in reverse. Deleting `dragonfly-operator` deletes the CRD, and with it every `Dragonfly` resource in the cluster.

## Operator

### How is the operator set up?

- Cluster-wide: it watches `Dragonfly` resources in every namespace. Upstream namespace name kept.
- Upstream all-in-one manifest by URL, pinned to a release tag.
- Restricted Pod Security on its namespace. Both images run as numeric user 65532, so `runAsNonRoot` passes.

### How do I upgrade the operator?

Bump the release tag in `k8s/dragonfly-operator/kustomization.yaml` and deploy. Read the release notes first: the API is `v1alpha1`, and v1.7.0 removed a field. The CRD is in the same manifest, so it upgrades with the operator.

### Why kapp `disable-original` on the CRD?

The CRD is ~470 KB, over kapp's 256 KiB annotation cap, so kapp skips the copy anyway. The patch makes it explicit, and `conversion: None` keeps the diff empty. Same as `psmdb-operator`.

## Operator HA

### Why two operator pods?

The operator does the Dragonfly failover. With one pod, a node failure that takes the operator and the Dragonfly master together stalls the promotion until the operator reschedules, possibly onto a new node (minutes).

### How do two operators work together?

Through a Lease (`31079dea.dragonflydb.io`), a lock with an expiry. Both pods run, but only the Lease holder runs the controllers and renews the Lease every few seconds. The other one waits. When the leader stops renewing, the standby takes the Lease after `leaseDurationSeconds: 15` and reads the state fresh from the cluster.

```sh
kubectl -n dragonfly-operator-system get lease -o custom-columns=HOLDER:.spec.holderIdentity,TRANSITIONS:.spec.leaseTransitions
```

### How long does a handover take?

About 15-20s (18s seen live during a rollout). The leader doesn't release the Lease on shutdown (upstream leaves `LeaderElectionReleaseOnCancel` off), so even a clean stop waits for it to expire.

### Can both act at once?

No. A leader that can't renew within its renew deadline (10s) stops itself, before the Lease can expire and pass to the other pod.

### Why a PDB?

So a node drain (Autopilot upgrades) evicts one operator pod at a time. With 2 pods and `minAvailable: 1`, the first eviction is allowed. The second waits until the replacement is Ready. It needs two replicas: with one, `minAvailable: 1` blocks every drain.

### Does the PDB start a new pod before removing the old one?

No, it only refuses evictions. Starting before removing is the Deployment's `maxSurge`, and that only applies to rollouts. The PDB doesn't help on a node crash either; the second replica covers that.

### Why spread constraints and not pod anti-affinity?

Cost. Autopilot requires 500m CPU per pod with pod anti-affinity: 1000m billed instead of 240m. Spread isn't held to that (accepted live at 120m). For two pods both give one per node.

### When is anti-affinity the right tool?

- To keep me *next to* another app (`podAffinity`). Spread can only push pods apart.
- To keep me away from a *different* app.
- For strictly one pod per node, ever. With `maxSkew: 1`, 4 pods on 2 nodes go 2 + 2.

Spreading your own replicas evenly: spread.

### How do I read the spread block?

Keep operator pods (`labelSelector`) evenly across nodes (`topologyKey: hostname`), off by at most 1 (`maxSkew: 1`). Assume at least 2 nodes (`minDomains: 2`). If that can't be met, stay Pending (`DoNotSchedule`), which makes Autopilot add a node.

### How is "evenly" checked?

Per candidate node: `skew = matching pods on it after placing − minimum`. Allowed if `skew ≤ maxSkew`.

The minimum is the fewest matching pods on any eligible node, before placing. Eligible: passes the pod's nodeSelector/nodeAffinity. Matching: `labelSelector` plus same `pod-template-hash`. With A: 2, B: 1, C: 0 the minimum is 0, so only C (skew 1) is allowed. A node can sit at most `maxSkew` above the emptiest one.

### Why `minDomains: 2`?

Spread only counts nodes that exist. On 1 node, that node is also the emptiest, so the minimum rises with every pod and skew stays 0: both pods fit "evenly" on one node (seen live). With fewer than `minDomains` nodes, the minimum is taken as 0. The second pod would make skew 2, so it waits for a new node.

### Why `matchLabelKeys: pod-template-hash`?

So only pods of the same rollout are counted. Otherwise old and new pods are counted together during a rollout, and the new ones land unevenly and stay that way.

## Autopilot and pod security

### Why change the upstream requests?

Upstream asks for 15m CPU per pod, under the Autopilot minimum, so Autopilot would raise it (`resource-adjustment`). Ours: manager 100m / 256Mi, kube-rbac-proxy 20m / 64Mi. Memory limit = request, no CPU limit.

### Why remove the upstream node affinity?

It pins the CPU architecture to a list that includes ppc64le and s390x, which GKE doesn't offer. Autopilot picks the architecture itself (amd64 unless asked), so the rule only adds a way to fail scheduling.

### What is kube-rbac-proxy?

A sidecar that puts authentication in front of the operator's metrics. Kept as upstream ships it. Scraping comes later, with a PodMonitoring (Managed Prometheus doesn't read ServiceMonitor).
