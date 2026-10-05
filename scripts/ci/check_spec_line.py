#!/usr/bin/env python3
"""
Check for spec traceability lines in PR bodies.

Validates that PR bodies contain either:
  - Spec: <epic>/<story> @ <sha> (7-40 lowercase hex)
  - Spec-Exempt: <reason> (non-empty)

Lines inside HTML comments and code fences are ignored.
The unfilled template placeholder is not counted.

Only pull requests that change behavior need the line: those whose Conventional Commits
title type is feat, fix, perf or revert (or whose title does not parse). Other types
(docs, ci, build, chore, test, refactor) and release-please's release PRs (head branch
`release-please--*`) are exempt without one. So are pull requests Yellowhammer opens from its
own Feature Branches (the last path segment of the head ref starts with `yh-`, e.g. `rozd/yh-x`):
their traceability is the Feature's Definition of Done, whose clauses cite the spec on the board,
and the body quotes each unmet clause's citation.
"""

import os
import re
import sys


SPEC_PATTERN = re.compile(
    r"^Spec: ([a-z0-9]+(?:-[a-z0-9]+)*)/([a-z0-9]+(?:-[a-z0-9]+)*) @ ([a-f0-9]{7,40})$"
)
EXEMPT_PATTERN = re.compile(r"^Spec-Exempt: (.+)$")
TEMPLATE_PLACEHOLDER = "Spec: <epic>/<story> @ <spec commit sha>"
CODE_FENCE_PATTERN = re.compile(r"^```")
TITLE_TYPE_PATTERN = re.compile(r"^([a-z]+)(?:\([^()]+\))?!?: ")
SPEC_REQUIRED_TYPES = {"feat", "fix", "perf", "revert"}
RELEASE_PR_BRANCH_PREFIX = "release-please--"
FEATURE_BRANCH_PREFIX = "yh-"


def exemption_reason(title, head_ref):
    """Return why this pull request needs no spec line, or None if it needs one."""
    if head_ref.startswith(RELEASE_PR_BRANCH_PREFIX):
        return "release-please release PR"
    if head_ref.rsplit("/", 1)[-1].startswith(FEATURE_BRANCH_PREFIX):
        return "Yellowhammer Feature Branch: its Definition of Done cites the spec on the board"
    match = TITLE_TYPE_PATTERN.match(title)
    if match and match.group(1) not in SPEC_REQUIRED_TYPES:
        return f"title type '{match.group(1)}' changes no behavior"
    return None


def is_in_html_comment(lines, line_idx):
    """Check if a line is inside an HTML comment block."""
    # A line counts as commented if a comment is open at its start, or opens on it.
    in_comment = False
    for i in range(line_idx):
        for marker in re.findall(r"<!--|-->", lines[i]):
            in_comment = marker == "<!--"
    return in_comment or "<!--" in lines[line_idx]


def is_in_code_fence(lines, line_idx):
    """Check if a line is inside a code fence (triple backticks)."""
    in_fence = False
    for i in range(line_idx + 1):
        line = lines[i]
        if CODE_FENCE_PATTERN.match(line.strip()):
            in_fence = not in_fence

    return in_fence


def check_spec_line(body):
    """
    Check PR body for spec traceability.

    Returns: (is_valid, matched_lines, error_messages)
    """
    lines = body.replace("\r\n", "\n").split("\n")
    matched_lines = []
    error_messages = []

    for idx, line in enumerate(lines):
        stripped = line.strip()

        # Skip empty lines
        if not stripped:
            continue

        # Skip if not a spec line
        if not (stripped.startswith("Spec:") or stripped.startswith("Spec-Exempt:")):
            continue

        # Check if in HTML comment or code fence
        if is_in_html_comment(lines, idx) or is_in_code_fence(lines, idx):
            continue

        # Check for template placeholder
        if stripped == TEMPLATE_PLACEHOLDER:
            continue

        # Try to match spec line
        spec_match = SPEC_PATTERN.match(stripped)
        if spec_match:
            epic, story, sha = spec_match.groups()
            matched_lines.append((idx + 1, stripped, "spec"))
            continue

        # Try to match exempt line
        exempt_match = EXEMPT_PATTERN.match(stripped)
        if exempt_match:
            reason = exempt_match.group(1).strip()
            if reason and reason != "<reason>":
                matched_lines.append((idx + 1, stripped, "exempt"))
                continue
            else:
                error_messages.append(
                    f"Line {idx + 1}: Spec-Exempt requires non-empty reason: {stripped}"
                )
                continue

        # If we got here, it starts with Spec: or Spec-Exempt: but is malformed
        if stripped.startswith("Spec:"):
            error_messages.append(
                f"Line {idx + 1}: Malformed spec line (expected 'Spec: <epic>/<story> @ <sha>'):\n  {stripped}"
            )
        elif stripped.startswith("Spec-Exempt:"):
            error_messages.append(
                f"Line {idx + 1}: Malformed exempt line (expected 'Spec-Exempt: <reason>'):\n  {stripped}"
            )

    is_valid = len(matched_lines) > 0 and len(error_messages) == 0

    return is_valid, matched_lines, error_messages


def main():
    reason = exemption_reason(
        os.environ.get("PR_TITLE", "").strip(), os.environ.get("PR_HEAD_REF", "").strip()
    )
    if reason:
        print(f"✓ Spec traceability not required: {reason}")
        return 0

    # Read PR body from environment or stdin
    body = os.environ.get("PR_BODY", "").strip()
    if not body:
        body = sys.stdin.read().strip()

    is_valid, matched_lines, error_messages = check_spec_line(body)

    if is_valid:
        print("✓ Spec traceability check passed")
        for line_num, line_text, line_type in matched_lines:
            print(f"  Line {line_num}: {line_text}")
        return 0
    else:
        print("::error title=Spec traceability::PR must include spec traceability", file=sys.stderr)
        print(
            "Expected at least one of:\n"
            "  1. Spec: <epic>/<story> @ <sha> (epic and story are lowercase slugs, sha is 7-40 hex chars)\n"
            "  2. Spec-Exempt: <reason> (for non-spec work)\n"
            "A PR titled with type docs, ci, build, chore, test or refactor, or opened by\n"
            "Yellowhammer from a Feature Branch whose last path segment starts with yh-\n"
            "(e.g., rozd/yh-x or feature/yh-thing), needs neither.",
            file=sys.stderr
        )

        if error_messages:
            print("\nMalformed lines found:", file=sys.stderr)
            for msg in error_messages:
                print(f"  {msg}", file=sys.stderr)
        else:
            print("\nNo valid spec traceability line found in PR body.", file=sys.stderr)

        return 1


if __name__ == "__main__":
    sys.exit(main())
