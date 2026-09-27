#!/usr/bin/env python3
"""
Check Conventional Commits formatting on PR titles and commit headers.

Validates that a header matches:
  <type>(<scope>)?!?: <description>

Allowed types: feat, fix, perf, revert, docs, refactor, test, ci, build, chore.
Scope is optional and parenthesized; `!` marks a breaking change. The description
must be non-empty. Release-please's own release commits (e.g.
`chore(main): release 0.2.0`) match the `chore` type and pass like any other.

Usage:
  check_conventional_commits.py --title "<pr title>"
  check_conventional_commits.py --range BASE..HEAD

Exit codes:
  0 - every checked header is valid
  1 - at least one header is malformed
"""

import argparse
import re
import subprocess
import sys


TYPES = ("feat", "fix", "perf", "revert", "docs", "refactor", "test", "ci", "build", "chore")

HEADER_PATTERN = re.compile(
    r"^(" + "|".join(TYPES) + r")(\([^()]+\))?!?: \S.*$"
)


def check_header(header):
    """Return True if a single commit/PR-title header is a valid Conventional Commit."""
    return bool(HEADER_PATTERN.match(header))


def commit_headers(commit_range):
    """
    Return the subject lines of every non-merge commit in `commit_range`
    (e.g. "BASE..HEAD"), as a list of (sha, subject) pairs.
    """
    result = subprocess.run(
        ["git", "log", "--no-merges", "--format=%H%x09%s", commit_range],
        check=True,
        capture_output=True,
        text=True,
    )
    headers = []
    for line in result.stdout.splitlines():
        if not line:
            continue
        sha, _, subject = line.partition("\t")
        headers.append((sha, subject))
    return headers


def main():
    parser = argparse.ArgumentParser(
        description="Check Conventional Commits formatting"
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--title", type=str, help="Check a single PR title")
    group.add_argument("--range", type=str, help="Check every non-merge commit in BASE..HEAD")
    args = parser.parse_args()

    failures = []

    if args.title is not None:
        if not check_header(args.title):
            failures.append((None, args.title))
    else:
        for sha, subject in commit_headers(args.range):
            if not check_header(subject):
                failures.append((sha, subject))

    if failures:
        print(
            "::error title=Conventional Commits::One or more headers do not follow "
            "Conventional Commits",
            file=sys.stderr,
        )
        print(
            "Expected '<type>(<scope>)?!?: <description>' with type one of: "
            + ", ".join(TYPES),
            file=sys.stderr,
        )
        for sha, subject in failures:
            location = f"{sha[:7]} " if sha else ""
            print(f"  {location}{subject}", file=sys.stderr)
        return 1

    print("✓ Conventional Commits check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
