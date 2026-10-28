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

- `secrets.users: mongo-system-users`: the operator's own accounts (clusterAdmin, userAdmin, clusterMonitor, databaseAdmin, backup). `internal-mongo-users` is the operator's copy.
- That Secret and `mongo-mongodb-encryption-key` come from Secret Manager (`infra/static/secrets.tf`) through GKE Secret Sync (`secretsync.yaml`), so every session gets the same key and passwords and a backup restores into a new cluster.
  - The synced Secrets must exist before the cluster resource. Otherwise the operator generates its own and Secret Sync can't take them over. kapp creates `mongo/secrets` first and waits until both are synced (`kapp-config.yaml`).
  - Only passwords are synced; the operator adds the `MONGODB_*_USER` keys. Secret Sync writes with server-side apply, so it leaves those alone.
  - Synced once, no rotation. To rotate a password, bump its version in `infra/static`, then change `spec.forceSynchronization` on the SecretSync; the operator then changes it in mongod. Older backups still hold the old password. Never rotate the encryption key this way: the data and every physical backup are encrypted with it.
- App users: `spec.users`, a password Secret per user, roles scoped to the app's database. Removing an entry doesn't drop the user.
- Passwords from Secret Manager through Secret Sync, like the system users (the operator needs a real Kubernetes Secret; the CSI add-on only mounts files).

## Dev access

See `../DEV-ACCESS.md`. Mongo's part: devs log in with their own `spec.users` user, never the system users, and the replica set needs member-name DNS through the tunnel.

## Data lifetime

Same as valkey: one session. `delete-psmdb-pvc` deletes StatefulSets, PVCs and the operator's own Secrets with the resource. Backups in GCS and the values in Secret Manager outlive it.

The synced Secrets are owned by their SecretSync, and a GKE admission policy lets only Secret Sync and the garbage collector delete them. The finalizer's delete gets `Forbidden` and retries until kapp has deleted the SecretSyncs, which is why they have no "delete after" rule: that would deadlock.

## Backups

PBM, physical only. A `backup-agent` sidecar in each mongod pod reads the data files from the shared volume and streams them, compressed, straight to GCS. Nothing is staged on disk.

- Bucket `lab-gke-2610-mongo-backup` in `infra/static`, prefix `mongo`. Rotation: an hourly CronJob (`backup-cleanup.yaml`) execs into a backup-agent and runs PBM's own cleanup: PITR slices 48h, backups 7d. PBM never deletes part of a chain or the slices a kept backup needs, so it keeps at least that much. Neither PBM nor the operator schedules it. It only runs while the cluster is up; the first run of a session catches up. No lifecycle rule on `mongo/`: PBM's cleanup is the only rotation there. Run it now:

  ```sh
  kubectl -n mongo create job --from=cronjob/backup-cleanup backup-cleanup-now
  ```
- Fulls for 90 days: PBM can only delete whole chains, so its 7-day cleanup takes each day's base with it. A second PBM storage would take a second full from mongod (more disk/network load on a member, holds PBM's one-operation lock, grows with data size). Instead a daily CronJob (`backup-copy.yaml`, 02:00 UTC) copies the newest finished base to `mongo-full/`: a GCS-side copy, no load on mongod. A base is a complete physical backup on its own; its `.pbm.json` has `type: incremental`, no `src_backup`, `status: done`. The script keeps the newest 90 there (`KEEP=90`; GCS lifecycle can't cap a count). It also deletes incomplete copies (data without `.pbm.json`, left by a failed copy or delete). The bucket has no lifecycle rules; all retention is in these CronJobs. Must stay outside `mongo/`: PBM lists its prefix recursively, so copies there would be imported and cleaned at 7 days. Run it now:

  ```sh
  kubectl -n mongo create job --from=cronjob/backup-copy backup-copy-now
  ```

  Monthly: on the 1st, `backup-copy-monthly` copies the newest full from `mongo-full/` to `mongo-monthly/`. Kept forever (no lifecycle rule), in the bucket's default storage class. Same script (`backup-copy.py`), different `SRC`/`DST`:

  ```sh
  kubectl -n mongo create job --from=cronjob/backup-copy-monthly backup-copy-monthly-now
  ```

  Restore from a copy: suspend the cleanup (it would delete a copy older than 7 days), copy `<name>/` and then `<name>.pbm.json` back into `mongo/`, resync, restore by name, then resume the cleanup:

  ```sh
  kubectl -n mongo patch cronjob backup-cleanup -p '{"spec":{"suspend":true}}'
  gcloud storage cp -r gs://lab-gke-2610-mongo-backup/mongo-full/<name>   # or mongo-monthly/ gs://lab-gke-2610-mongo-backup/mongo/
  gcloud storage cp gs://lab-gke-2610-mongo-backup/mongo-full/<name>.pbm.json gs://lab-gke-2610-mongo-backup/mongo/
  kubectl -n mongo exec statefulset/mongo-rs0 -c backup-agent -- pbm config --force-resync
  # ... restore ...
  kubectl -n mongo patch cronjob backup-cleanup -p '{"spec":{"suspend":false}}'
  ```
- Later, for disaster recovery: today every copy is in one bucket, and the agents can delete all of it. Move the copies to a separate bucket (another region, ideally another project) with a retention lock, written by a create-only identity running outside the cluster. Monthlies typically get their own bucket with Archive as its default storage class (cheapest per GB, 365-day minimum, still online).
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
- Restorable across sessions: a physical restore needs the same encryption key, and backups include the system users. Both come from Secret Manager (see Users).

## Restore

Never automatic: a new cluster starts empty. A restore is a deliberate choice of backup and point in time, and it stops the whole replset.

`restore.yaml`, created by hand (outside kapp) into a running cluster:

- `backupSource` (a GCS path), not `backupName`: the backup's Kubernetes object went away with the session that took it.
- The operator first checks the backup in GCS itself, as its own KSA. `infra/dynamic/iam.tf` gives it read access; the agents do the restore.
- The operator turns PITR off during the restore. After it, the old chain doesn't continue: deploy again for a new base.

A new session's deploy writes an **empty** base and PITR range into the same `mongo/` prefix, so the newest backup and "latest" PITR are the empty cluster. Always pick a backup and time from before it.

```sh
# 1. PBM lists every backup in mongo/, from all sessions, and the PITR ranges (UTC)
kubectl -n mongo exec statefulset/mongo-rs0 -c backup-agent -- pbm list

# 2. a base or incremental taken before the target time, and a time inside a PITR range after it
BACKUP=2026-10-28T00:00:21Z
DATE="2026-10-28 10:15:00"
sed -e "s/BACKUP_NAME/$BACKUP/" -e "s/PITR_DATE/$DATE/" k8s/mongo/restore.yaml | kubectl -n mongo create -f -

# 3. wait for state ready (several minutes: pods stop, files download, oplog replays, pods restart)
kubectl -n mongo get psmdb-restore -w

# 4. new base and PITR on the restored data
k8s/deploy.sh mongo
```

To restore from `mongo-full/` or `mongo-monthly/`, copy it back into `mongo/` first (Backups). PITR on top of an incremental hasn't been tried yet; if PBM refuses, use the chain's base.

Teardown: restores carry no finalizer; `kubectl -n mongo delete psmdb-restore --all` before destroying the operator keeps it tidy.

### Drill

Untested backups aren't backups. Run this once, and again after changing anything in backups, secrets or the operator version.

```sh
# password into mongosh through stdin, never on screen or in history
mongo_eval() {
  kubectl -n mongo get secret mongo-system-users -o jsonpath='{.data.MONGODB_DATABASE_ADMIN_PASSWORD}' | base64 -d |
    kubectl -n mongo exec -i mongo-rs0-0 -c mongod -- bash -c 'read -r PW; mongosh --quiet \
      "mongodb://databaseAdmin:$PW@mongo-rs0.mongo.svc.cluster.local/admin?replicaSet=rs0" --eval "$1"' _ "$1"
}
```

1. Session A, after deploy (base done): write a marker, note the time.

   ```sh
   mongo_eval 'db.getSiblingDB("drill").marker.insertOne({at: new Date()})'
   date -u +"%Y-%m-%d %H:%M:%S"
   ```

2. Wait until a PITR range in `pbm list` covers that time (slices every 10 min), then write a second marker that the restore must *not* bring back.
3. Tear down fully: `destroy.sh mongo`, delete backups, `destroy.sh psmdb-operator`, `tofu destroy` dynamic.
4. Session B: apply dynamic, deploy operator and mongo (new empty cluster). `mongo_eval 'db.getSiblingDB("drill").marker.find()'` shows nothing.
5. Restore (above) with the session A base and the noted time.
6. Check:
   - the first marker is back, the second isn't
   - `kubectl -n mongo get psmdb mongo` is `ready` (the operator logs in with Secret Manager's passwords, which match the restored users)
   - the replset is the same data, encrypted with the same key: no "unable to decrypt" in `kubectl -n mongo logs mongo-rs0-0 -c mongod`
7. `k8s/deploy.sh mongo` for a new base; `pbm status` shows PITR running again.

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
