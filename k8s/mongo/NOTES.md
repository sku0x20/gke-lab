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

- Bucket `lab-gke-2610-mongo-backup` in `infra/static`, prefix `mongo`. Rotation: an hourly CronJob (`backup-cleanup.yaml`) execs into a backup-agent and runs PBM's own cleanup: PITR slices 48h, backups 7d. PBM never deletes part of a chain or the slices a kept backup needs, so it keeps at least that much. Neither PBM nor the operator schedules it. It only runs while the cluster is up; the first run of a session catches up. The bucket's 90-day lifecycle rule (plus 7 days of soft delete) is a backstop. Run it now:

  ```sh
  kubectl -n mongo create job --from=cronjob/backup-cleanup backup-cleanup-now
  ```
- Fulls for 30 days: PBM can only delete whole chains, so its 7-day cleanup takes each day's base with it. A second PBM storage would take a second full from mongod (more disk/network load on a member, holds PBM's one-operation lock, grows with data size). Instead a daily CronJob (`backup-copy.yaml`, 02:00 UTC) copies the newest finished base to `mongo-full/`: a GCS-side copy, no load on mongod. A base is a complete physical backup on its own; its `.pbm.json` has `type: incremental`, no `src_backup`, `status: done`. The bucket deletes `mongo-full/` at 30 days. Must stay outside `mongo/`: PBM lists its prefix recursively, so copies there would be imported and cleaned at 7 days. Run it now:

  ```sh
  kubectl -n mongo create job --from=cronjob/backup-copy backup-copy-now
  ```

  Restore from a copy: copy `<name>/` and then `<name>.pbm.json` back into `mongo/`, resync, restore by name:

  ```sh
  gcloud storage cp -r gs://lab-gke-2610-mongo-backup/mongo-full/<name> gs://lab-gke-2610-mongo-backup/mongo/
  gcloud storage cp gs://lab-gke-2610-mongo-backup/mongo-full/<name>.pbm.json gs://lab-gke-2610-mongo-backup/mongo/
  kubectl -n mongo exec statefulset/mongo-rs0 -c backup-agent -- pbm config --force-resync
  ```
- Later, for disaster recovery: today every copy is in one bucket, and the agents can delete all of it. Move the 30-day copies to a separate bucket (another region, ideally another project) with a 30-day retention lock, written by a create-only identity running outside the cluster.
- No keys: without `credentialsSecret`, PBM uses Workload Identity. The pods run as KSA `mongo`, which has `roles/storage.objectUser` on the bucket (`infra/dynamic/iam.tf`).
- Strategy:
  - daily `incremental-base` (full physical) at 00:00 UTC
  - hourly `incremental` (changes since the previous backup in the chain)
  - PITR: oplog slices every 10 min, so at most ~10 min of writes are lost.
  - PBM has no differential backups.
- Schedules only fire while the cluster is up, and a new cluster has no chain. Without a base the incrementals fail and PITR has nothing to replay onto. So every deploy takes one (`backup-base.yaml`), even a deploy with no changes. After a restore, deploy again for a new base:

  ```sh
  k8s/deploy.sh mongo
  ```

  The operator has no trigger for this (tasks are cron only), so kapp does it:
  - `kapp.k14s.io/nonce` plus `update-strategy: always-replace`: the backup object is recreated on every deploy.
  - `change-rule`: created only after the cluster's change group is done.
  - `kapp-config.yaml` wait rules: the cluster is done when the operator has seen the new spec (`observedGeneration`), `state` is `ready`, and no `pendingSmartUpdate` is left. Without that wait, the backup would start while a rollout is pending and run first, because a smart update waits for running backups.
  - `deploy.sh mongo` now blocks until the cluster is ready and the base is done. A failed base fails the deploy.
- Restarts outside a deploy (node upgrades, evictions) aren't covered; the daily base catches them.
- The chain lives on the node that took the base. If that member is gone, the next incremental fails until a new base. Why, and the open restart question: `backup-doc.md`.
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
