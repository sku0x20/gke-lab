# Incremental backup history

Two different "histories". Only one of them is tied to a node.

## 1. PBM's catalogue: which backups exist

Each backup's name and type, and which backup each incremental builds on.

- Stored in PBM's collections in the `admin` db (replicated to all members) and as a metadata file next to each backup in GCS.
- Owner: PBM. Survives losing a pod; the GCS copy outlives the cluster.

## 2. WiredTiger's change map: which disk blocks changed

An incremental doesn't compare data. It asks the storage engine of one specific mongod which blocks changed since the last backup.

- The base runs on one member, e.g. `mongo-rs0-1`, and gives its mongod an ID (backup X).
- That mongod's WiredTiger then tracks which blocks of its data files change.
- The next incremental asks the same mongod for blocks changed since X, uploads only those, then says "now track from Y".
- Owner: WiredTiger inside that mongod. Not PBM, not replicated.

It can't move to another member: replication copies operations, not blocks. Each member writes its own files with its own layout, so block 1234 on `rs0-1` isn't the same data on `rs0-2`. That's why PBM runs every incremental on the base's node.

```
                   PBM catalogue (admin db + GCS)      ← replicated, survives
                   "inc#2 → inc#1 → base X"
                              │
        ┌─────────────────────┼─────────────────────┐
     rs0-0                  rs0-1                  rs0-2
     own files            own files              own files
                     + WiredTiger change map
                       "blocks changed since X"   ← only here
```

## When the chain breaks

Only when that member's change map is gone or unreachable:

- Its agent is down when an incremental runs: PBM can't ask it, so the incremental fails.
- Its data is rebuilt from scratch (e.g. a resync from another member): new files, no map.
- Not when the pod moves to another node: the PVC (its files) moves with it.

A broken chain loses no data: PITR slices don't depend on it, so a restore uses the last good backup plus oplog, just slower. The next base (daily, or the one every deploy takes) starts a new chain.

## Open question: does a restart wipe the map?

If WiredTiger keeps the map on disk (metadata files on the PVC), restarts are harmless. If only in memory, every mongod restart wipes it, and every rollout (which restarts all 3 pods) breaks the chain. The PBM docs don't say.

Test: take a base, note which pod took it, delete that pod, wait for 3/3, run one incremental.

```sh
kubectl -n mongo get psmdb-backup -o wide        # which pod took the base
kubectl -n mongo delete pod mongo-rs0-<n>
kubectl -n mongo create -f - <<'EOF'
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBBackup
metadata:
  generateName: incr-
spec:
  clusterName: mongo
  storageName: gcs
  type: incremental
EOF
kubectl -n mongo get psmdb-backup -w             # ready = survives restarts; error = doesn't
```

Either way, the base every deploy takes restarts the chain after a rollout.

# PITR

PITR doesn't use the change map. It uses the oplog: every write as an operation ("insert this doc"). Secondaries copy and replay it, so all 3 members hold the same oplog. Blocks differ per member; the oplog doesn't.

## Slicing

- PBM picks one agent in the replset to slice; any member works.
- Every 10 min (`oplogSpanMin`) it uploads the new oplog entries to GCS as one slice, e.g. 10:00 → 10:10.
- If that agent dies, another continues from the last uploaded timestamp.
- Result: one continuous timeline in GCS, not tied to any node.

```
backups:   base X ── inc 1 ── inc 2 ──✗ (chain broken)
oplog:     |10:00|10:10|10:20|10:30|10:40|10:50|11:00| ...   ← unaffected
```

## Restore to time T

1. PBM picks the newest backup (base or incremental) that finished before T.
2. Restores its files.
3. Replays the slices from that backup's end up to T.

With the chain broken after `inc 2`, a restore to 11:00 uses `inc 2` and replays everything since. Same data, more replay, so slower.

## What breaks it

- No backup to replay onto: the base every deploy takes covers a new cluster.
- A gap: the oplog is fixed-size, and old entries roll off. If no agent uploads for longer than the oplog holds, those entries are gone. `pbm status` shows the gap; times inside it can't be restored. The next backup starts a new timeline.
- After a restore: history after that point is rewritten, and later slices no longer apply. Deploy again for a new base.
- Rotation: `backup-cleanup.yaml` deletes slices older than 48h (back to the nearest backup).

Here at most ~10 min of writes are lost, the slice not yet uploaded. At teardown everything up to ~10 min before the destroy is already in GCS.
