"""Copy the newest finished PBM base backup from SRC to DST (GCS-side copy, no load on mongod).

Used by the backup-copy CronJobs (backup-copy.yaml):
  daily:   mongo/      -> mongo-full/     (newest 90 kept)
  monthly: mongo-full/ -> mongo-monthly/  (kept forever)
Idempotent: an already copied base is skipped. With KEEP set, copies beyond the newest KEEP
in DST are deleted after each run. Incomplete copies (data without metadata) are deleted too.
"""

import json
import os
import subprocess
import sys

SRC = os.environ["SRC"]  # e.g. gs://bucket/mongo
DST = os.environ["DST"]
KEEP = int(os.environ.get("KEEP", "0"))  # 0: keep all


def gcloud(*args, check=True):
    # stdout returned; stderr goes to the pod log
    return subprocess.run(["gcloud", "storage", *args], check=check,
                          stdout=subprocess.PIPE, text=True)


def is_finished_base(meta):
    # a base is type incremental with no src_backup
    return (meta["type"] == "incremental" and not meta.get("src_backup")
            and meta["status"] == "done")


def backups(prefix):
    # names of complete backups (those with metadata), newest first: names are timestamps
    urls = gcloud("ls", f"{prefix}/*.pbm.json", check=False).stdout.split()
    names = [u.rsplit("/", 1)[1].removesuffix(".pbm.json") for u in urls]
    return sorted(names, reverse=True)


def folders(prefix):
    # top-level backup folders; gcloud prints them with a trailing /
    urls = gcloud("ls", f"{prefix}/", check=False).stdout.split()
    # not the prefix itself (listed when a console-made folder object exists)
    return [u.rstrip("/").rsplit("/", 1)[1] for u in urls
            if u.endswith("/") and u != f"{prefix}/"]


for name in backups(SRC):
    if is_finished_base(json.loads(gcloud("cat", f"{SRC}/{name}.pbm.json").stdout)):
        break
else:
    sys.exit("no finished base")

if name in backups(DST):
    print(f"{name} already copied")
else:
    gcloud("cp", "-r", f"{SRC}/{name}", f"{DST}/")
    # metadata last: its presence marks a complete copy
    gcloud("cp", f"{SRC}/{name}.pbm.json", f"{DST}/")
    print(f"copied {name}")

if KEEP:
    for old in backups(DST)[KEEP:]:
        # metadata first: a half-deleted copy no longer looks complete
        gcloud("rm", f"{DST}/{old}.pbm.json")
        gcloud("rm", "-r", f"{DST}/{old}")
        print(f"deleted {old}")

# data without metadata is left by a failed copy or delete. Skip this run's base: a manual
# run may overlap a scheduled one (the CronJob's Forbid doesn't cover manual jobs)
complete = set(backups(DST))
for folder in folders(DST):
    if folder not in complete and folder != name:
        gcloud("rm", "-r", f"{DST}/{folder}")
        print(f"deleted incomplete {folder}")
