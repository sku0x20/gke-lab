# MongoDB

Percona Server for MongoDB through the Percona operator (PSMDB). Two kapp apps:

- `psmdb-operator`: CRDs, RBAC, operator Deployment, and the `mongo` namespace.
- `mongo`: one `PerconaServerMongoDB` resource; the operator creates everything else (StatefulSet, Services, Secrets, TLS).

## Why an operator

A replica set needs `rs.initiate()`, a keyfile, member add/remove, users, TLS, and primary-aware restarts. Plain manifests mean scripting all of that. Percona Server also has features MongoDB Community lacks (audit log, encryption at rest).

## Operator

- Namespaced (Role, watches only `mongo`), so the database lives in the operator's namespace.
- Destroy `mongo` before `psmdb-operator`: the finalizers (`delete-psmdb-pods-in-order`, `delete-psmdb-pvc`) run in the operator.
- Upstream manifests by URL, pinned to a release tag; upgrade = bump the tag, then `crVersion`.
- `RECONCILE_INTERVAL` 30s (upstream 5s): the periodic re-check of state Kubernetes sends no events for. Kubernetes changes still reconcile immediately.
- Telemetry left on.

## Upgrades

- `upgradeOptions.apply: disabled`: the operator never changes `spec.image`, so git stays the source of truth (an auto-upgrade would fight kapp).
- Upgrade = edit `spec.image`, deploy. SmartUpdate restarts secondaries one at a time, steps down the primary, restarts it last.
- `setFCV: true`: after a major upgrade rolls out, featureCompatibilityVersion is raised, which ends the rollback window.

## Autopilot

- Pod anti-affinity (one member per node) needs at least 500m CPU per pod, or GKE Warden rejects the StatefulSet. 3 × 500m / 1Gi is billed.
- System pods (kube-dns) can preempt the operator while Autopilot adds nodes. Harmless: it holds no state and resumes from the cluster.

## Pod Security (restricted)

- Setting `podSecurityContext` replaces the operator's defaults, so `runAsUser`/`fsGroup` 1001 are repeated.
- `readOnlyRootFilesystem` needs `env: HOME=/`. Otherwise mongosh warns on stdout about `~/.mongodb`, the operator's primary check (stdout must be exactly `true`) fails, and the replset never initializes. Upstream #2594 (K8SPSMDB-1853).

## Users

- `secrets.users: mongo-system-users`: the operator's own accounts (clusterAdmin, userAdmin, clusterMonitor, databaseAdmin, backup), generated if missing. Edit a password there to rotate it; `internal-mongo-users` is the operator's copy.
- App users: `spec.users`, a password Secret per user, roles scoped to the app's database. Removing an entry doesn't drop the user.
- Passwords from Secret Manager (like valkey). Open question: the operator needs a real Kubernetes Secret, the add-on mounts files.

## Dev access

See `../DEV-ACCESS.md`. Mongo's part: devs log in with their own `spec.users` user, never the system users, and the replica set needs member-name DNS through the tunnel.

## Data lifetime

Same as valkey: one session. `delete-psmdb-pvc` deletes StatefulSets, PVCs and the generated Secrets with the resource. Backups in GCS outlive it.

## Backups

PBM, physical only. A `backup-agent` sidecar in each mongod pod reads the data files from the shared volume and streams them, compressed, straight to GCS. Nothing is staged on disk.

- Bucket `lab-gke-2610-mongo-backup` in `infra/static`, prefix `mongo`. Expiry: the bucket's 90-day lifecycle rule (plus 7 days of soft delete), not PBM.
- No keys: without `credentialsSecret`, PBM uses Workload Identity. The pods run as KSA `mongo`, which has `roles/storage.objectUser` on the bucket (`infra/dynamic/iam.tf`).
- Strategy:
  - daily `incremental-base` (full physical) at 00:00 UTC
  - hourly `incremental` (changes since the previous backup in the chain)
  - PITR: oplog slices every 10 min, so at most ~10 min of writes are lost.
  - PBM has no differential backups.
- Schedules only fire while the cluster is up, and a new cluster has no chain. So after every deploy or restore, take a base. Without it the incrementals fail and PITR has nothing to replay onto:

  ```sh
  kubectl create -f k8s/mongo/backup-base.yaml
  ```
- The chain lives on the node that took the base. If that member is gone, the next incremental fails until a new base.
- Never `percona.com/delete-backup`. Scheduled backups get it unless `retention.deleteFromStorage: false`, and per-session teardown would then delete the files in GCS (or hang namespace deletion: the operator's fallback storage client ignores Workload Identity). `retention.count` only trims the Kubernetes objects.
- Teardown, in this order:

  ```sh
  k8s/destroy.sh mongo
  kubectl -n mongo delete psmdb-backup --all   # GCS files stay
  k8s/destroy.sh psmdb-operator
  ```

  Every started backup carries the operator's `internal.percona.com/release-lock` finalizer, which only the operator removes. Left for the namespace deletion, they'd keep it Terminating once the operator is gone.
- Restore into a new session uses `backupSource` (a GCS path), since the backup objects are gone. A physical restore stops the whole replset.
- Not yet restorable across sessions: a physical restore needs the same encryption key (`mongo-mongodb-encryption-key`), and backups include the system users (`mongo-system-users`). Both are generated per session today. Next step: keep them in Secret Manager.

## Audit log (not enabled)

Percona Server feature. Tested against 8.0.32-14 in docker. Goes under `replsets[].configuration`; a change rolls the pods. Once on, it can only be turned off with a restart.

```yaml
      configuration: |
        auditLog:
          destination: console # stdout, so it reaches Cloud Logging
          # DDL, user/role and replset changes; every failure; logins and writes
          # by anyone but the system users. Not reads, not per-connection events
          filter: >-
            { "$or": [
              { "atype": { "$nin": ["authenticate", "authCheck", "clientMetadata", "logout"] } },
              { "result": { "$ne": 0 } },
              { "atype": "authenticate",
                "param.user": { "$nin": ["clusterAdmin", "clusterMonitor", "userAdmin", "backup", "__system"] } },
              { "atype": "authCheck",
                "param.command": { "$in": ["insert", "update", "delete", "findAndModify"] },
                "users.user": { "$nin": ["clusterAdmin", "clusterMonitor", "userAdmin", "backup", "__system"] } }
            ] }
        setParameter:
          # CRUD successes are audited only with this on; Percona warns it costs performance
          auditAuthorizationSuccess: true
```

- Without `clientMetadata`/`logout` in the `$nin`, every probe and operator connection is logged.
- Find audit lines in Cloud Logging with `jsonPayload.atype:*`.
