# Dragonfly FAQ

Dragonfly (Redis-compatible), run by the Dragonfly operator.

## Basics

### What gets deployed?

Two kapp apps:

- `dragonfly-operator`: the `dragonfly` namespace, the CRD, RBAC and the operator Deployment.
- `dragonfly`: one `Dragonfly` resource in that namespace. The operator creates the StatefulSet, Services and PDB.

Same split as `psmdb-operator` and `mongo`.

### One shared instance or one per app?

One shared, highly available instance, like mongo. For sessions, queues and shared state that must survive a node failure without downtime. An app that wants a cache or something private gets its own valkey (cheap, no HA).

Per-app Dragonfly doesn't pay off: with HA each instance is 3 pods (1.5 CPU billed). Dragonfly's threads also remove valkey's main reason to split (one slow command blocking everyone).

Eviction is still instance-wide: this one never evicts. A workload that needs both eviction and HA gets a second `Dragonfly`, and the operator is granted its namespace explicitly.

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

Deploy `dragonfly-operator`, then `dragonfly`: the namespace comes with the operator. Destroy in reverse. Deleting `dragonfly-operator` deletes the namespace and the CRD, and with them the `Dragonfly` resource and its pods.

## Operator

### How is the operator set up?

- Namespaced: it watches only `dragonfly` and has rights only there.
- Upstream all-in-one manifest by URL, pinned to a release tag, moved into `dragonfly` by kustomize.
- Restricted Pod Security on its namespace. Both images run as numeric user 65532, so `runAsNonRoot` passes.

### Why namespaced?

Upstream binds its role cluster-wide: create and delete on pods, Services, ConfigMaps, StatefulSets and PDBs in every namespace. A bug there could delete mongo's StatefulSet. One shared instance needs one namespace.

- `WATCH_NAMESPACE` from the pod's own namespace: the operator lists and watches only there. Not `--watch-current-namespace`: it reads a kubeconfig, which pods don't have.
- `rolebinding.yaml` binds upstream's ClusterRole with a RoleBinding: same rules, this namespace only. Upstream's ClusterRoleBinding is deleted by a patch, which fails the build if upstream renames it.
- kube-rbac-proxy keeps its ClusterRoleBinding: TokenReviews and SubjectAccessReviews are cluster-scoped APIs.
- The CRD is cluster-scoped regardless.

```sh
kubectl auth can-i delete statefulsets -n mongo --as=system:serviceaccount:dragonfly:dragonfly-operator-controller-manager  # no
```

### Why do the patches still say `dragonfly-operator-system`?

Kustomize matches patches against the upstream names, before `namespace:` moves the objects. With `dragonfly` in the patch, the build fails with "no resource matches".

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
kubectl -n dragonfly get lease -o custom-columns=HOLDER:.spec.holderIdentity,TRANSITIONS:.spec.leaseTransitions
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

## Dragonfly pods

### Why three pods?

One master, two replicas. On failover the operator promotes the replica with the highest replication offset (the most data received), and one replica is still left for the next failure. With one replica, losing it leaves the master alone until the new pod has synced.

More replicas don't make writes safer: replication is still async. The `dragonfly` Service points at the master only, so they add no read capacity either.

### Why anti-affinity here and spread for the operator?

Strictly one pod per node, so a node failure takes at most one. That's the anti-affinity case. It costs the Autopilot minimum of 500m CPU per pod (1500m billed for three); Dragonfly's two threads use it.

The operator pods are stateless and cheap to lose, so spread at 120m is enough there.

### Why pin the image?

The operator's default is the Dragonfly version it was built with, so an operator upgrade would also upgrade the data store. Pinned, they upgrade separately. The operator rolls replicas first, then hands the master role to an updated replica.

### Why `--proactor_threads=2`?

With no CPU limit, Dragonfly starts one thread per node core, and it exits if `maxmemory` is under 256 MiB per thread. `maxmemory` comes from the 1Gi memory limit, so a node with 5+ cores would crash the pod. Pinned, node size doesn't matter.

### Why run as user 999?

Restricted Pod Security rejects root. The image starts as root and drops to `dfly` (999) in its entrypoint; started as 999, the entrypoint skips that step. Setting `podSecurityContext` replaces the operator's default (`fsGroup: 999` only), so all of it is set.

### Why no PVC, unlike valkey?

The second copy is the replicas' memory, not a disk. Valkey runs one pod, so its disk (AOF) is the only copy.

- Replica restarts: full sync from the master over the network.
- Master restarts: the operator promotes a replica; the old master comes back as a replica and syncs.
- Dragonfly has no AOF, so a disk could only hold snapshots. GCS is better for those: it outlives a zone and the cluster, and a fresh pod loads from it with no disk to reattach.

The cost: all three pods down at once (bad rollout, cluster gone) loses every write since the last snapshot. The snapshot interval is the recovery point for that case.

The operator adds a PVC only with `snapshot.persistentVolumeClaimSpec` or `tiering.persistentVolumeClaimSpec`. We set neither, so nothing in the pod survives a restart.

### How do I know all pods are up?

Not from `status.phase`: it turns `Ready` once the master runs, before the replicas exist (seen live). kapp doesn't wait either, the resource has no conditions. Wait on the StatefulSet:

```sh
kubectl -n dragonfly wait sts/dragonfly --for=jsonpath='{.status.readyReplicas}'=3
kubectl -n dragonfly exec dragonfly-0 -- redis-cli info replication   # on the master: connected_slaves:2, state=online
```

### What are the "Replication error: ExecutionState cancelled" lines?

Harmless, one on the master per replica joining. The operator sends `REPLICAOF` twice about 160 ms apart, so the replica drops its first full sync and starts another (seen in the replica log). Empty, that's milliseconds. With GBs of data, every replica start copies the dataset twice.

## Autopilot and pod security

### Why change the upstream requests?

Upstream asks for 15m CPU per pod, under the Autopilot minimum, so Autopilot would raise it (`resource-adjustment`). Ours: manager 100m / 256Mi, kube-rbac-proxy 20m / 64Mi. Memory limit = request, no CPU limit.

### Why remove the upstream node affinity?

It pins the CPU architecture to a list that includes ppc64le and s390x, which GKE doesn't offer. Autopilot picks the architecture itself (amd64 unless asked), so the rule only adds a way to fail scheduling.

### What is kube-rbac-proxy?

A sidecar that puts authentication in front of the operator's metrics. Kept as upstream ships it. Scraping comes later, with a PodMonitoring (Managed Prometheus doesn't read ServiceMonitor).
