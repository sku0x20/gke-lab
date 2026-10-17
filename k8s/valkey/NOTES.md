# Valkey

Plain kustomize, no Helm or operator. Add an operator only when ops actually need one.

## Why Valkey

BSD-licensed fork of Redis 7.2 under the Linux Foundation; Redis itself went AGPL/proprietary. Same protocol, so `redis-cli` and Redis clients work unchanged.

## Topology

Start with a single instance (StatefulSet, `replicas: 1`).

- Skip Sentinel at first. It only adds failover, needs Sentinel-aware clients, and tracks pod IPs, which fits k8s poorly.
- Boot is fast, so a short planned outage is fine: image upgrades, GKE node upgrades, rescheduling.
- Need zero downtime? Sentinel (failover, data fits one node). Outgrown one node? Cluster (sharding, multi-key ops need same-slot `{tag}` keys).

## Upgrades

StatefulSets can't surge: `valkey-0` is one identity on a ReadWriteOnce disk, so the old pod stops before the new one starts. Expect seconds to about a minute (save on SIGTERM, disk reattach, data load).

- Clients must retry and reconnect.
- `terminationGracePeriodSeconds` must cover the save on shutdown.
- No PodDisruptionBudget: with one replica it only blocks node drains.
- GKE node upgrades will restart it more often than our own upgrades. Use maintenance windows.

## Per app or shared

One instance per app or service once an app needs its own. Sharing hurts: commands run one at a time (a slow command blocks everyone), and eviction policy and persistence are instance-wide (cache wants `allkeys-lru`, queues and sessions want `noeviction`). An extra instance costs a few MB.

Postgres is the other way round: one server, a database and role per service. Strong isolation inside, expensive to run more instances.

## Namespace

`valkey` for now: a namespace is a security and ownership boundary (RBAC, quotas), not a category like `db`. An app-private Valkey can later live in that app's namespace. Decide before data exists: PVCs can't move between namespaces.
