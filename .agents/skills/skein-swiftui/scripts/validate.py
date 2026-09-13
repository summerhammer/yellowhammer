#!/usr/bin/env python3
"""Validate the skein-swiftui skill.

Checks the agentskills.io frontmatter rules and the conventions this skill relies on
for lazy loading:

  * every bold **area/topic** cross-reference resolves to a real sibling file, because
    those are load instructions — a dangling one sends the agent looking for a file
    that does not exist;
  * every reference file opens with a scope line naming its neighbours, so an agent
    that lands on the wrong file can navigate instead of loading broadly;
  * SKILL.md routes to every file and references/index.md lists every file, so nothing
    is unreachable;
  * the platform-target boilerplate stays hoisted in SKILL.md rather than being
    re-added to individual files.

Run from anywhere:  python3 scripts/validate.py
"""

import os
import re
import sys
import glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []


def check(condition, message):
    print(("  ok   " if condition else "  FAIL ") + message)
    if not condition:
        failures.append(message)


def bold_refs(text):
    """**area/topic** -> area-topic.md. The notation used inside reference files."""
    return {f"{a}-{b}.md" for a, b in re.findall(r"\*\*([a-z-]+)/([a-z-]+)\*\*", text)}


def file_refs(text):
    """`area-topic.md` -> area-topic.md. The notation used in references/index.md."""
    return set(re.findall(r"`([a-z-]+(?:-[a-z-]+)*\.md)`", text))


def main():
    skill_path = os.path.join(ROOT, "SKILL.md")
    skill = open(skill_path).read()

    print("agentskills.io specification")
    check(skill.startswith("---\n"), "SKILL.md opens with YAML frontmatter")
    fm = skill.split("---")[1]

    def field(key):
        m = re.search(rf"^{key}: (.*)$", fm, re.M)
        return m.group(1).strip() if m else None

    name, desc, comp = field("name"), field("description"), field("compatibility")
    check(bool(name) and re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", name) and len(name) <= 64,
          f"name is 1-64 lowercase/digit/hyphen chars, no edge or doubled hyphens: {name!r}")
    check(name == os.path.basename(ROOT), f"name matches the parent directory ({name})")
    check(bool(desc) and len(desc) <= 1024, f"description is 1-1024 chars ({len(desc or '')})")
    check(comp is None or 0 < len(comp) <= 500, f"compatibility is 1-500 chars ({len(comp or '')})")
    check(skill.count("\n") + 1 < 500, f"SKILL.md is under 500 lines ({skill.count(chr(10)) + 1})")
    check(not glob.glob(os.path.join(ROOT, "references", "*", "")),
          "references/ is flat, keeping file references one level deep")

    print("lazy-loading contract")
    refs_dir = os.path.join(ROOT, "references")
    paths = sorted(glob.glob(os.path.join(refs_dir, "*.md")))
    files = {os.path.basename(p) for p in paths} - {"index.md"}

    dangling, no_scope, boilerplate = set(), [], []
    for p in paths:
        base = os.path.basename(p)
        text = open(p).read()
        # index.md documents the notation with a placeholder; exempt it
        targets = bold_refs(text) - ({"area-topic.md"} if base == "index.md" else set())
        dangling |= targets - files
        if base != "index.md":
            intro = "\n".join(text.split("\n")[1:9])
            if not re.search(r"Companion to|liv\w+ in \*\*", intro):
                no_scope.append(base)
            if re.search(r"Targets the latest|back-deployment shims|availability shims", text):
                boilerplate.append(base)

    check(not dangling, f"every **area/topic** resolves to a real file (dangling: {sorted(dangling)})")
    check(not no_scope, f"every reference file opens with a scope line (missing: {no_scope})")
    check(not boilerplate, f"platform boilerplate stays hoisted in SKILL.md (re-added in: {boilerplate})")

    unrouted = files - bold_refs(skill) - file_refs(skill)
    check(not unrouted, f"SKILL.md routes to every file (unrouted: {sorted(unrouted)})")

    index = open(os.path.join(refs_dir, "index.md")).read()
    unlisted = files - bold_refs(index) - file_refs(index)
    check(not unlisted, f"references/index.md lists every file (unlisted: {sorted(unlisted)})")

    print(f"\n{len(files)} reference files + index.md")
    if failures:
        print(f"\n{len(failures)} check(s) failed")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
