#!/usr/bin/env python3
"""
Carry source modification times across a cached SwiftPM `.build`.

SwiftPM decides what to recompile by comparing each source's mtime with the one it
recorded at the last build. A fresh checkout stamps every file with the checkout time, so
a restored `.build` saves only the dependencies: every one of the package's own modules
recompiles on every run.

  record  - after a build, write each tracked file's blob id and mtime into the manifest
  restore - after a checkout, give every file whose blob id is unchanged its recorded mtime
            back; an edited file keeps the checkout time, so it alone is recompiled

The manifest lives inside `.build`, so it travels in the same cache entry as the build it
describes.

Exit codes:
  0 - done (a missing manifest on restore is not an error: there is nothing to restore)
  2 - usage error
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def tracked_blobs(root: Path) -> dict[str, str]:
    """Map each tracked path under `root` (relative to `root`) to its git blob id."""
    output = subprocess.run(
        ["git", "ls-files", "--stage", "-z", "--", "."],
        cwd=root, check=True, capture_output=True, text=True,
    ).stdout
    blobs = {}
    for entry in output.split("\0"):
        if not entry:
            continue
        meta, path = entry.split("\t", 1)
        _mode, blob, _stage = meta.split()
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
    restored = changed = 0
    for path, blob in tracked_blobs(root).items():
        entry = recorded.get(path)
        if entry is None or entry[0] != blob:
            changed += 1
            continue
        os.utime(root / path, ns=(entry[1], entry[1]))
        restored += 1
    print(f"Restored {restored} source mtimes; {changed} new or changed files keep the checkout time")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["record", "restore"])
    parser.add_argument("--root", type=Path, required=True, help="the package directory")
    parser.add_argument("--manifest", type=Path, help="defaults to <root>/.build/source-mtimes.json")
    args = parser.parse_args(argv)
    manifest = args.manifest or args.root / ".build" / "source-mtimes.json"
    return record(args.root, manifest) if args.command == "record" else restore(args.root, manifest)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
