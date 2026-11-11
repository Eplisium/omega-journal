#!/usr/bin/env python3
"""Set every tracked file's mtime to the time of the last commit that touched it.

    python3 scripts/restore_mtimes.py

CI helper. A fresh `actions/checkout` stamps every file with "now", so a restored
`.build` cache looks older than all sources and the Swift driver recompiles
everything. With commit times, files a commit did not change keep the mtime the
cached build recorded, and the driver recompiles only what changed (it compares
each source's mtime with the one in its build record, so any different commit
time triggers a rebuild). Needs the full history (`fetch-depth: 0`); with a
shallow clone, files older than the shallow boundary get the boundary commit's
time, which only costs extra recompiles, never a stale build.
"""
import os
import subprocess
import sys


def main() -> int:
    root = subprocess.run(["git", "rev-parse", "--show-toplevel"], check=True,
                          capture_output=True, text=True).stdout.strip()
    os.chdir(root)
    tracked = set(subprocess.run(["git", "ls-files", "-z"], check=True,
                                 capture_output=True, text=True).stdout.split("\0")) - {""}
    # Never back-date a file with uncommitted changes: the build would think it is unchanged.
    dirty = set(subprocess.run(["git", "diff", "--name-only", "-z", "HEAD"], check=True,
                               capture_output=True, text=True).stdout.split("\0"))
    tracked -= dirty
    log = subprocess.run(["git", "-c", "core.quotePath=false", "log", "--format=%x00%ct", "--name-only", "--no-renames", "HEAD"],
                         check=True, capture_output=True, text=True).stdout
    stamps = {}
    when = None
    for line in log.split("\n"):
        if line.startswith("\0"):
            when = int(line[1:])
        elif line and when is not None and line in tracked and line not in stamps:
            stamps[line] = when
            if len(stamps) == len(tracked):
                break
    for path, ts in stamps.items():
        try:
            os.utime(path, (ts, ts), follow_symlinks=False)
        except OSError:
            pass
    print(f"restore_mtimes: {len(stamps)} of {len(tracked)} tracked files set to their last commit time")
    return 0


if __name__ == "__main__":
    sys.exit(main())
