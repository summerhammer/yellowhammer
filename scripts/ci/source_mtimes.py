#!/usr/bin/env python3
"""
Carry source modification times across cached SwiftPM or Xcode build output.

SwiftPM decides what to recompile by comparing each source's mtime with the one it
recorded at the last build. A fresh checkout stamps every file with the checkout time, so
a restored `.build` saves only the dependencies: every one of the package's own modules
recompiles on every run.

  record  - after a build, write each tracked file's blob id and mtime into the manifest
  restore - after a checkout, give every file whose blob id is unchanged its recorded mtime
            back; an edited file keeps the checkout time, so it alone is recompiled

The manifest defaults to `.build/source-mtimes.json`. For Xcode, use the repository root
and put the manifest inside the cached DerivedData with `--manifest`. Only regular tracked
files participate: a tracked symlink may point outside the checkout and must not be followed.

Exit codes:
  0 - done (a missing manifest, or a tracked file missing from the working tree, is not
      an error on restore: there is nothing to restore for it)
  2 - usage error
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def tracked_blobs(root: Path) -> dict[str, str]:
    """Map regular tracked paths under `root` (relative to `root`) to git blob ids."""
    output = subprocess.run(
        ["git", "ls-files", "--stage", "-z", "--", "."],
        cwd=root, check=True, capture_output=True, text=True,
    ).stdout
    blobs = {}
    for entry in output.split("\0"):
        if not entry:
            continue
        meta, path = entry.split("\t", 1)
        mode, blob, _stage = meta.split()
        # Never follow tracked symlinks or descend into submodules when restoring mtimes.
        if mode not in ("100644", "100755"):
            continue
        blobs[path] = blob
    return blobs


def record(root: Path, manifest: Path) -> int:
    entries = {}
    for path, blob in tracked_blobs(root).items():
        try:
            entries[path] = [blob, (root / path).stat().st_mtime_ns]
        except FileNotFoundError:
            continue
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps(entries, sort_keys=True))
    print(f"Recorded {len(entries)} source mtimes in {manifest}")
    return 0


def restore(root: Path, manifest: Path) -> int:
    if not manifest.exists():
        print(f"No manifest at {manifest}; nothing to restore")
        return 0
    recorded = json.loads(manifest.read_text())
    restored = changed = missing = 0
    for path, blob in tracked_blobs(root).items():
        entry = recorded.get(path)
        if entry is None or entry[0] != blob:
            changed += 1
            continue
        # A tracked file absent from the working tree (sparse checkout, removed by an
        # earlier step, skipped by the checkout) has no mtime to restore, as in `record`.
        try:
            os.utime(root / path, ns=(entry[1], entry[1]))
        except FileNotFoundError:
            missing += 1
            continue
        restored += 1
    print(
        f"Restored {restored} source mtimes; {changed} new or changed files keep the checkout time; "
        f"{missing} tracked files are missing from the working tree"
    )
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["record", "restore"])
    parser.add_argument("--root", type=Path, required=True, help="the package or repository directory")
    parser.add_argument("--manifest", type=Path, help="defaults to <root>/.build/source-mtimes.json")
    args = parser.parse_args(argv)
    manifest = args.manifest or args.root / ".build" / "source-mtimes.json"
    return record(args.root, manifest) if args.command == "record" else restore(args.root, manifest)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
