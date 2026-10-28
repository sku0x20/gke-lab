# MongoDB FAQ

Percona Server for MongoDB, run by the Percona operator (PSMDB).

## Basics

### What gets deployed?

Two kapp apps:

- `psmdb-operator`: CRDs, RBAC, the operator Deployment, and the `mongo` namespace.
- `mongo`: one `PerconaServerMongoDB` resource. The operator creates everything else (StatefulSet, Services, Secrets, TLS).

### Why an operator and not plain manifests?

A replica set needs `rs.initiate()`, a keyfile, member add/remove, users, TLS, and primary-aware restarts. With plain manifests we'd script all of that. Percona Server also has features MongoDB Community lacks (audit log, encryption at rest).

### How is the operator set up?

- Namespaced: a Role that watches only `mongo`, so the database lives in the operator's namespace.
- Upstream manifests by URL, pinned to a release tag.
- `RECONCILE_INTERVAL` 30s (upstream 5s). That's the periodic re-check for state Kubernetes sends no events for; Kubernetes changes still reconcile immediately.
- Telemetry left on.

### In what order do I deploy and destroy?

Deploy `psmdb-operator`, then `mongo`. Destroy in reverse:

```sh
k8s/destroy.sh mongo
kubectl -n mongo delete psmdb-backup,psmdb-restore --all   # GCS files stay
k8s/destroy.sh psmdb-operator
```

- `mongo` goes first because its finalizers (`delete-psmdb-pods-in-order`, `delete-psmdb-pvc`) run inside the operator.
- Backup objects go before the operator: every started backup carries the `internal.percona.com/release-lock` finalizer, which only the operator removes. Left behind, they keep the namespace stuck in Terminating.

### How long does the data live?

One session, like valkey. `delete-psmdb-pvc` deletes the StatefulSets, PVCs and the operator's own Secrets. Backups in GCS and the values in Secret Manager outlive it.

## Upgrades

### How do I upgrade MongoDB?

Edit `spec.image` and deploy. SmartUpdate restarts the secondaries one at a time, steps down the primary, and restarts it last.

### Why doesn't the operator upgrade itself?

`upgradeOptions.apply: disabled`, so git stays the source of truth. An auto-upgrade would fight kapp.

### When does a major upgrade become final?

`setFCV: true` raises featureCompatibilityVersion after the rollout. That ends the rollback window.

### How do I upgrade the operator?

Bump the release tag in `k8s/psmdb-operator`, then `crVersion` in `psmdb.yaml`.

## Autopilot and pod security

### Why 500m CPU per pod?

Pod anti-affinity (one member per node) needs at least 500m, or GKE Warden rejects the StatefulSet. 3 × 500m / 1Gi is billed.

### The operator pod got preempted. Is that a problem?

No. System pods (kube-dns) can preempt it while Autopilot adds nodes. It holds no state and resumes from the cluster.

### Why is `runAsUser`/`fsGroup` 1001 repeated in `psmdb.yaml`?

Setting `podSecurityContext` replaces the operator's defaults.

### Why `env: HOME=/`?

It's needed for `readOnlyRootFilesystem`. Without it, mongosh warns on stdout about `~/.mongodb`, the operator's primary check (stdout must be exactly `true`) fails, and the replset never initializes. Upstream #2594 (K8SPSMDB-1853).

## Users and secrets

### Which users exist?

- System users, in `mongo-system-users` (`spec.secrets.users`): clusterAdmin, userAdmin, clusterMonitor, databaseAdmin, backup. These are the operator's own accounts. `internal-mongo-users` is the operator's copy.
- App users, in `spec.users`: a password Secret per user, with roles scoped to the app's database. Removing an entry doesn't drop the user.

### Where do the passwords and the encryption key come from?

Secret Manager (`infra/static/secrets.tf`), copied into Kubernetes Secrets by GKE Secret Sync (`secretsync.yaml`). Every session gets the same key and passwords, so a backup restores into a new cluster.

- Only passwords are synced. The operator adds the `MONGODB_*_USER` keys itself, and Secret Sync (server-side apply) leaves them alone.
- App users get the same treatment later. The operator needs a real Kubernetes Secret, and the CSI add-on only mounts files.

### Why must the Secrets exist before the cluster?

Otherwise the operator generates its own random key and passwords, and Secret Sync can't take those Secrets over. So kapp creates `mongo/secrets` first and waits until both are synced (`kapp-config.yaml`).

### How do I rotate a password?

Bump its version in `infra/static`, then change `spec.forceSynchronization` on the SecretSync. The operator then changes it in mongod. Older backups still hold the old password.

Never rotate the encryption key this way: the data and every physical backup are encrypted with it.

### Why does the operator log `Forbidden` on teardown?

A GKE admission policy lets only Secret Sync and the garbage collector delete synced Secrets. The finalizer's delete fails and retries until kapp has deleted the SecretSyncs and the garbage collector removes the Secrets. That's why the SecretSyncs have no "delete after" rule: it would deadlock.

### How do devs log in?

See `../DEV-ACCESS.md`. Devs use their own `spec.users` user, never the system users. The replica set needs member-name DNS through the tunnel.

## Backups

### How are backups taken?

PBM, physical only. A `backup-agent` sidecar in each mongod pod reads the data files and streams them, compressed, straight to GCS. Nothing is staged on disk.

- Bucket `lab-gke-2610-mongo-backup` (`infra/static`), prefix `mongo/`.
- No keys: without `credentialsSecret`, PBM uses Workload Identity. The pods run as KSA `mongo`, which has `roles/storage.objectUser` on the bucket (`infra/dynamic/iam.tf`).

### What's the schedule?

- Daily `incremental-base` (a full physical backup) at 00:00 UTC.
- Hourly `incremental` (changes since the previous backup in the chain).
- PITR: oplog slices every 10 min, so at most ~10 min of writes are lost.
- PBM has no differential backups.

### Does a deploy take a backup?

No. Bases come from the `daily-base` task (00:00 UTC) or by hand. A deploy only waits until the cluster is `ready` (`kapp-config.yaml`).

### What happens on a new cluster until the first base?

No protection. Incrementals fail (nothing to chain to), and PITR waits, because it needs a base to replay onto. Take a base by hand right after the first deploy.

### How do I take a base by hand?

```sh
kubectl -n mongo create -f k8s/mongo/backup-base.yaml
kubectl -n mongo get psmdb-backup -w   # until ready
```

Take one:

- on a new cluster
- after a restore
- after a rollout or a member loss (see below)

### What about restarts?

The chain lives on the node that took the base. If that member restarts or is gone, the next incremental may fail until a new base. The daily base catches it, or take one by hand. Details and the open restart question: `backup-doc.md`.

### How long are backups kept?

| What | Where | Kept | By |
|---|---|---|---|
| PITR slices | `mongo/` | 48h | `backup-cleanup` (hourly :30) |
| bases + incrementals | `mongo/` | 7 days | `backup-cleanup` |
| daily fulls | `mongo-full/` | newest 90 | `backup-copy` (02:00 UTC) |
| monthly fulls | `mongo-monthly/` | forever | `backup-copy-monthly` (1st, 03:00) |

The bucket has no lifecycle rules; all retention lives in these CronJobs. They only run while the cluster is up, and the first run of a session catches up.

### How does `backup-cleanup` work?

It execs into a backup-agent and runs PBM's own cleanup. PBM never deletes part of a chain, or the slices a kept backup needs, so it keeps at least that much. Neither PBM nor the operator schedules it. Run it now:

```sh
kubectl -n mongo create job --from=cronjob/backup-cleanup backup-cleanup-now
```

### Why copy fulls instead of a second PBM storage?

PBM only deletes whole chains, so its 7-day cleanup takes each day's base with it. A second PBM storage would take a second full from mongod: more disk and network load on a member, it holds PBM's one-operation lock, and it grows with data size. A GCS-side copy puts no load on mongod.

`backup-copy` copies the newest finished base (`.pbm.json` with `type: incremental`, no `src_backup`, `status: done`) to `mongo-full/`. A base is a complete physical backup on its own. The script:

- keeps the newest 90 (`KEEP=90`; GCS lifecycle can't cap a count)
- deletes incomplete copies (data without `.pbm.json`)

On the 1st, `backup-copy-monthly` runs the same script (`backup-copy.py`) from `mongo-full/` to `mongo-monthly/`, with no `KEEP`. Run them now:

```sh
kubectl -n mongo create job --from=cronjob/backup-copy backup-copy-now
kubectl -n mongo create job --from=cronjob/backup-copy-monthly backup-copy-monthly-now
```

### Why can't the copies live under `mongo/`?

PBM lists its prefix recursively, so it would import them and clean them at 7 days.

### Why no `percona.com/delete-backup` finalizer?

Per-session teardown would delete the files in GCS, or hang namespace deletion, because the operator's fallback storage client ignores Workload Identity. Scheduled backups get it unless `retention.deleteFromStorage: false`. `retention.count` only trims the Kubernetes objects.

### Is this enough for disaster recovery?

Not yet. Every copy sits in one bucket, and the agents can delete all of it. The next step: a separate bucket (another region, ideally another project) with a retention lock, written by a create-only identity outside the cluster. Monthlies typically get their own bucket with Archive as the default storage class (cheapest per GB, 365-day minimum, still online).

## Restore

### Does a new cluster restore automatically?

No, it starts empty. A restore is a deliberate choice of backup and point in time, and it stops the whole replset.

### Can I restore into a brand-new, empty cluster?

Yes. Same flow as any restore, because the key and system users come from Secret Manager. The cluster must be running first: a restore goes into a live cluster.

### What's different in a new session?

- Don't take a base before the restore. It would back up the **empty** cluster into the same `mongo/` prefix, and "newest" would mean empty. If the session runs past 00:00, `daily-base` does exactly that, so always pick the backup by time.
- Suspend `backup-cleanup` right after the deploy. Its first run (:30) can delete the old session's PITR slices older than 48h and backups older than 7 days.

### How do I restore?

```sh
# 0. right after deploy.sh mongo, before :30
kubectl -n mongo patch cronjob backup-cleanup -p '{"spec":{"suspend":true}}'

# 1. every backup in mongo/ (all sessions) and the PITR ranges, in UTC
kubectl -n mongo exec statefulset/mongo-rs0 -c backup-agent -- pbm list

# 2. a backup taken before the target time, and a time inside a PITR range after it
BACKUP=2026-10-28T00:00:21Z
DATE="2026-10-28 10:15:00"
sed -e "s/BACKUP_NAME/$BACKUP/" -e "s/PITR_DATE/$DATE/" k8s/mongo/restore.yaml | kubectl -n mongo create -f -

# 3. wait for ready (minutes: pods stop, files download, oplog replays, pods restart)
kubectl -n mongo get psmdb-restore -w

# 4. new base on the restored data (PITR resumes from it), then resume the cleanup
kubectl -n mongo create -f k8s/mongo/backup-base.yaml
kubectl -n mongo get psmdb-backup -w   # until ready
kubectl -n mongo patch cronjob backup-cleanup -p '{"spec":{"suspend":false}}'
```

### Why does `restore.yaml` use a GCS path, not a backup name?

`backupName` needs the backup's Kubernetes object, which went away with the session that took it. `backupSource` points straight at the files.

### Why does the operator need bucket access too?

Before restoring, the operator itself checks that the backup exists and is complete, as its own KSA `percona-server-mongodb-operator`. `infra/dynamic/iam.tf` gives it read-only access. The agents (KSA `mongo`) do the actual restore.

### Why a new base after a restore?

The operator turns PITR off during the restore, and the old chain doesn't continue. A new base restarts incrementals and PITR on the restored data.

### Can I restore from `mongo-full/` or `mongo-monthly/`?

Yes. Copy it back into `mongo/` first, then restore it by name:

```sh
kubectl -n mongo patch cronjob backup-cleanup -p '{"spec":{"suspend":true}}'   # else it deletes copies older than 7 days
gcloud storage cp -r gs://lab-gke-2610-mongo-backup/mongo-full/<name> gs://lab-gke-2610-mongo-backup/mongo/   # or mongo-monthly/
gcloud storage cp gs://lab-gke-2610-mongo-backup/mongo-full/<name>.pbm.json gs://lab-gke-2610-mongo-backup/mongo/
kubectl -n mongo exec statefulset/mongo-rs0 -c backup-agent -- pbm config --force-resync
# ... restore as above ...
```

Data first, `.pbm.json` last: PBM treats a backup as present once its metadata is.

### Can I use PITR on top of an incremental?

Not tried yet. If PBM refuses, use the chain's base.

### I see a `resource-adjustment` annotation during the restore. Why?

The operator adds a `pbm-init` init container with no resource requests, and we can't set them. Autopilot may adjust it until the StatefulSet is put back.

### How do I know restore actually works?

Run the drill once, and again after changing anything in backups, secrets or the operator version. Untested backups aren't backups.

```sh
# password into mongosh through stdin, never on screen or in history
mongo_eval() {
  kubectl -n mongo get secret mongo-system-users -o jsonpath='{.data.MONGODB_DATABASE_ADMIN_PASSWORD}' | base64 -d |
    kubectl -n mongo exec -i mongo-rs0-0 -c mongod -- bash -c 'read -r PW; mongosh --quiet \
      "mongodb://databaseAdmin:$PW@mongo-rs0.mongo.svc.cluster.local/admin?replicaSet=rs0" --eval "$1"' _ "$1"
}
```

1. Session A, after the deploy and a base by hand: write a marker, note the time.

   ```sh
   mongo_eval 'db.getSiblingDB("drill").marker.insertOne({at: new Date()})'
   date -u +"%Y-%m-%d %H:%M:%S"
   ```

2. Wait until a PITR range in `pbm list` covers that time, then write a second marker that the restore must *not* bring back.
3. Tear down fully: the destroy order above, then `tofu destroy` dynamic.
4. Session B: apply dynamic, deploy operator and mongo, suspend `backup-cleanup`. `mongo_eval 'db.getSiblingDB("drill").marker.find()'` shows nothing.
5. Restore with the session A backup and the noted time. Watch `kubectl -n mongo get pods -w`: pods restart with `pbm-init`. A `FailedCreate` event means a pod-security or Autopilot rejection.
6. Check:
   - the first marker is back, the second isn't
   - `kubectl -n mongo get psmdb mongo` is `ready` (the operator logs in with Secret Manager's passwords, which match the restored users)
   - no "unable to decrypt" in `kubectl -n mongo logs mongo-rs0-0 -c mongod` (same key)
7. Take a base by hand and resume `backup-cleanup` (restore step 4); `pbm status` shows PITR running again.

## Audit log

### Is auditing on?

No. It's tested against 8.0.32-14 in docker, but not enabled. It goes under `replsets[].configuration`; a change rolls the pods, and once on it can only be turned off with a restart.

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

### Why exclude `clientMetadata` and `logout`?

Without them in the `$nin`, every probe and operator connection is logged.

### How do I find audit lines?

In Cloud Logging, filter on `jsonPayload.atype:*`.
