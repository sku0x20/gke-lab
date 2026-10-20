"""Copy the newest finished PBM base backup from SRC to DST (GCS-side copy, no load on mongod).

Used by the backup-copy CronJobs (backup-copy.yaml):
  daily:   mongo/      -> mongo-full/     (kept 30 days)
  monthly: mongo-full/ -> mongo-monthly/  (kept 365 days, Archive)
Idempotent: an already copied base is skipped.
"""

import json
import os
import subprocess
import sys

SRC = os.environ["SRC"]  # e.g. gs://bucket/mongo
DST = os.environ["DST"]
STORAGE_CLASS = os.environ.get("STORAGE_CLASS")  # empty: the bucket's default


def gcloud(*args, check=True):
    # stdout returned; stderr goes to the pod log
    return subprocess.run(["gcloud", "storage", *args], check=check,
                          stdout=subprocess.PIPE, text=True)


def is_finished_base(meta):
    # a base is type incremental with no src_backup
    return (meta["type"] == "incremental" and not meta.get("src_backup")
            and meta["status"] == "done")


# newest first: backup names are timestamps
urls = gcloud("ls", f"{SRC}/*.pbm.json", check=False).stdout.split()
for url in sorted(urls, reverse=True):
    if is_finished_base(json.loads(gcloud("cat", url).stdout)):
        name = url.rsplit("/", 1)[1].removesuffix(".pbm.json")
        break
else:
    sys.exit("no finished base")

if gcloud("ls", f"{DST}/{name}.pbm.json", check=False).returncode == 0:
    print(f"{name} already copied")
    sys.exit()

opts = [f"--storage-class={STORAGE_CLASS}"] if STORAGE_CLASS else []
gcloud("cp", *opts, "-r", f"{SRC}/{name}", f"{DST}/")
# metadata last: its presence marks a complete copy
gcloud("cp", *opts, f"{SRC}/{name}.pbm.json", f"{DST}/")
print(f"copied {name}")
