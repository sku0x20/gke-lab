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
