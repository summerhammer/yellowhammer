#!/usr/bin/env python3
"""
Release gate (P15.4): turns a `rehearsal_suite.py run` into release evidence, and turns that
evidence into a pass/fail the release checklist can act on.

  record --app PATH --team KEY --evidence-directory DIR [--scenario N ...] [--act-timeout SECONDS]
    Runs the suite (via `rehearsal_suite.py run`, with its own work directory nested inside
    `--evidence-directory`) and writes to the evidence directory: `suite.log` (the suite's
    stdout/stderr, tee'd as it runs), `journals/` (a copy of every Journal snapshot the run left
    behind), `night-cards.md` (every Night Card the run's Journals hold, per run directory and
    Night, linked through the scratch Linear app credential), and `verdict.json` (commit sha, tree
    cleanliness, timestamp, the scenarios selected, the suite's exit code, and a PASS/FAIL per
    scenario parsed from the suite's own summary). Exits with the suite's exit code, or nonzero if
    the evidence itself could not be written.

  check --evidence-directory DIR [--commit SHA]
    Exits 0 only if `verdict.json` exists, `passed` is true, all scenarios passed, and its commit
    matches `--commit` (default: `git rev-parse HEAD`). Otherwise prints why and exits 1. This is
    the command a release checklist runs to be blocked by a failed scenario.

Python stdlib only; no network access except the read-only Linear GraphQL call `record` makes to
resolve each Night Card's `url` (falls back to the bare issue id on any failure).
"""

import argparse
import json
import re
import shutil
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SUITE_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = SUITE_DIR.parent
REPO_ROOT = SCRIPTS_DIR.parent

#: The suite currently names 13 scenarios (`scenarios.py`, `README.md`). Kept as a constant here
#: rather than importing `scenarios.py` so `check` (the command a release checklist runs) stays a
#: light read of `verdict.json`, with no dependency on the suite's own (heavier) module chain.
TOTAL_SCENARIOS = 13
ALL_SCENARIOS = tuple(range(1, TOTAL_SCENARIOS + 1))

SUMMARY_HEADER = "=== Summary ==="
SUMMARY_LINE = re.compile(r"^(PASS|FAIL) \[(\d+)\] (.*)$")

ISSUE_URL_QUERY = "query($id: String!) { issue(id: $id) { url } }"


def _load_module(name, path):
    import importlib.util

    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


scratch_linear = _load_module("scratch_linear", SCRIPTS_DIR / "scratch-linear" / "scratch_linear.py")


# MARK: - git


def git_commit_sha(repo_root=REPO_ROOT):
    result = subprocess.run(
        ["git", "-C", str(repo_root), "rev-parse", "HEAD"], capture_output=True, text=True
    )
    if result.returncode != 0:
        raise RuntimeError(f"git rev-parse HEAD failed: {result.stderr.strip()}")
    return result.stdout.strip()


def git_tree_dirty(repo_root=REPO_ROOT):
    result = subprocess.run(
        ["git", "-C", str(repo_root), "status", "--porcelain"], capture_output=True, text=True
    )
    if result.returncode != 0:
        raise RuntimeError(f"git status --porcelain failed: {result.stderr.strip()}")
    return bool(result.stdout.strip())


# MARK: - Running the suite and parsing its summary


def run_suite(
    app, team, work_directory, scenario_numbers=None, act_timeout=None, python_executable=None, installation=None
):
    """Runs `rehearsal_suite.py run` as a subprocess, tee'ing every line to stdout as it arrives.
    Returns (returncode, lines) — `lines` is every line of combined stdout/stderr, in order."""
    python_executable = python_executable or sys.executable
    command = [
        python_executable, str(SUITE_DIR / "rehearsal_suite.py"), "run",
        "--app", str(app), "--team", team, "--work-directory", str(work_directory),
    ]
    if installation is not None:
        command += ["--board-connection", installation]
    for number in scenario_numbers or []:
        command += ["--scenario", str(number)]
    if act_timeout is not None:
        command += ["--act-timeout", str(act_timeout)]

    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1
    )
    lines = []
    for line in process.stdout:
        line = line.rstrip("\n")
        print(line, flush=True)
        lines.append(line)
    process.wait()
    return process.returncode, lines


def parse_summary(lines):
    """Parses the `PASS [n] title` / `FAIL [n] title` lines `print_summary` writes after
    `=== Summary ===`. Per-check lines (`ChecksRecorder.expect`) share the same shape but appear
    before that marker, so they are never in range."""
    try:
        start = lines.index(SUMMARY_HEADER)
    except ValueError:
        return []
    results = []
    for line in lines[start + 1:]:
        match = SUMMARY_LINE.match(line)
        if not match:
            continue
        status, number, title = match.groups()
        results.append({"number": int(number), "title": title, "passed": status == "PASS"})
    return results


# MARK: - Journal snapshots and Night Cards


def copy_journal_snapshots(work_directory, journals_directory):
    """Copies every `*.db` (and its `-wal` sidecar, if present) under `work_directory` into
    `journals_directory`, preserving its relative path. Returns the original paths, sorted."""
    db_files = sorted(work_directory.glob("**/*.db"))
    for db_file in db_files:
        relative = db_file.relative_to(work_directory)
        dest = journals_directory / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(db_file, dest)
        wal = db_file.with_name(db_file.name + "-wal")
        if wal.exists():
            shutil.copyfile(wal, dest.with_name(dest.name + "-wal"))
    return db_files


def group_snapshots_by_run(db_files, work_directory):
    """Groups snapshot paths by their top-level subdirectory under `work_directory` — one such
    directory per scenario run (`rehearsal_suite.py`'s `slug`), and so per Project a scenario used."""
    groups = {}
    for db_file in db_files:
        top = db_file.relative_to(work_directory).parts[0]
        groups.setdefault(top, []).append(db_file)
    return groups


def collect_night_cards(groups):
    """For each run directory, reads the Night Cards recorded in its latest (most complete)
    snapshot. Returns {run label: [(night_start, night_card_issue_id), ...]}, Night Cards only."""
    entries = {}
    for label, files in groups.items():
        latest = sorted(files)[-1]
        connection = sqlite3.connect(str(latest))
        connection.row_factory = sqlite3.Row
        try:
            rows = connection.execute(
                "SELECT night_start, night_card_issue_id FROM night ORDER BY id"
            ).fetchall()
        except sqlite3.OperationalError:
            rows = []
        finally:
            connection.close()
        entries[label] = [
            (row["night_start"], row["night_card_issue_id"]) for row in rows if row["night_card_issue_id"]
        ]
    return entries


class _NoOverrideArgs:
    yh = None

    def __init__(self, installation=None):
        self.installation = installation


def build_linear_client(configuration_directory, transport=None, keychain_reader=None, installation=None):
    transport = transport or scratch_linear.HTTPTransport()
    keychain_reader = keychain_reader or scratch_linear.keychain_token_pair
    return scratch_linear.build_client(
        configuration_directory, _NoOverrideArgs(installation), transport, keychain_reader=keychain_reader
    )


def resolve_night_card_links(issue_ids, configuration_directory=None, transport=None, installation=None):
    """Maps each issue id to its Linear `url`, read through the scratch app credential. Falls back
    to the bare issue id — for any single issue, or for all of them — on any failure: a missing
    credential, a network error, or Linear refusing the request."""
    if not issue_ids:
        return {}
    configuration_directory = configuration_directory or scratch_linear.DEFAULT_CONFIGURATION_DIRECTORY
    try:
        client = build_linear_client(configuration_directory, transport=transport, installation=installation)
    except Exception:  # noqa: BLE001 - any setup failure just means every link falls back
        client = None

    links = {}
    for issue_id in issue_ids:
        url = None
        if client is not None:
            try:
                data = client.graphql(ISSUE_URL_QUERY, {"id": issue_id})
                url = (data.get("issue") or {}).get("url")
            except Exception:  # noqa: BLE001 - a fetch failure falls back for this issue only
                url = None
        links[issue_id] = url or issue_id
    return links


def write_night_cards_markdown(entries, links, path):
    lines = ["# Night Cards", ""]
    if not any(entries.values()):
        lines.append("No Night Cards were recorded.")
    else:
        for label in sorted(entries):
            rows = entries[label]
            if not rows:
                continue
            lines.append(f"## {label}")
            lines.append("")
            for night_start, issue_id in rows:
                link = links.get(issue_id, issue_id)
                lines.append(f"- {night_start}: [{issue_id}]({link})")
            lines.append("")
    path.write_text("\n".join(lines).rstrip() + "\n")


def write_evidence(
    work_directory, evidence_directory, configuration_directory=None, transport=None, installation=None
):
    """Copies every Journal snapshot into `evidence_directory/journals/` and writes
    `night-cards.md`. Raises on any failure — the caller treats that as evidence not written."""
    journals_directory = evidence_directory / "journals"
    journals_directory.mkdir(parents=True, exist_ok=True)
    db_files = copy_journal_snapshots(work_directory, journals_directory)
    groups = group_snapshots_by_run(db_files, work_directory)
    entries = collect_night_cards(groups)
    issue_ids = sorted({issue_id for rows in entries.values() for _, issue_id in rows})
    links = resolve_night_card_links(
        issue_ids, configuration_directory=configuration_directory, transport=transport,
        installation=installation,
    )
    write_night_cards_markdown(entries, links, evidence_directory / "night-cards.md")


# MARK: - record


def utc_now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def record_command(args):
    evidence_directory = args.evidence_directory.expanduser().resolve()
    evidence_directory.mkdir(parents=True, exist_ok=True)
    work_directory = evidence_directory / "work"
    work_directory.mkdir(parents=True, exist_ok=True)

    try:
        commit = git_commit_sha()
        dirty = git_tree_dirty()
    except RuntimeError as error:
        print(f"release_gate: could not read git state: {error}", file=sys.stderr)
        return 1

    selected = sorted(set(args.scenario)) if args.scenario else list(ALL_SCENARIOS)

    returncode, lines = run_suite(
        app=args.app, team=args.team, work_directory=work_directory,
        scenario_numbers=args.scenario, act_timeout=args.act_timeout,
        installation=args.installation,
    )

    log_text = "\n".join(lines)
    (evidence_directory / "suite.log").write_text(log_text + ("\n" if log_text else ""))

    summary = parse_summary(lines)

    evidence_written = True
    try:
        write_evidence(work_directory, evidence_directory, installation=args.installation)
    except Exception as error:  # noqa: BLE001 - any evidence failure blocks the checklist below
        print(f"release_gate: could not write evidence: {error}", file=sys.stderr)
        evidence_written = False

    passed = (
        returncode == 0
        and not dirty
        and len(selected) == TOTAL_SCENARIOS
        and len(summary) == TOTAL_SCENARIOS
        and all(result["passed"] for result in summary)
    )

    verdict = {
        "commit": commit,
        "dirty": dirty,
        "timestamp": utc_now_iso(),
        "scenarios_selected": selected,
        "exit_code": returncode,
        "scenario_results": summary,
        "passed": passed,
    }
    (evidence_directory / "verdict.json").write_text(json.dumps(verdict, indent=2) + "\n")

    if not evidence_written:
        return returncode if returncode != 0 else 1
    return returncode


# MARK: - check


def check_command(args):
    evidence_directory = args.evidence_directory.expanduser().resolve()
    verdict_path = evidence_directory / "verdict.json"
    if not verdict_path.is_file():
        print(f"release_gate: no verdict.json in {evidence_directory}", file=sys.stderr)
        return 1

    try:
        verdict = json.loads(verdict_path.read_text())
    except json.JSONDecodeError as error:
        print(f"release_gate: could not parse {verdict_path}: {error}", file=sys.stderr)
        return 1

    try:
        expected_commit = args.commit or git_commit_sha()
    except RuntimeError as error:
        print(f"release_gate: could not read git state: {error}", file=sys.stderr)
        return 1

    problems = []
    if not verdict.get("passed"):
        problems.append("verdict.json reports passed: false")

    results = verdict.get("scenario_results") or []
    failing = [result.get("number") for result in results if not result.get("passed")]
    if len(results) != TOTAL_SCENARIOS or failing:
        problems.append(
            f"not all {TOTAL_SCENARIOS} scenarios passed (ran {len(results)}, failing {failing})"
        )

    actual_commit = verdict.get("commit")
    if actual_commit != expected_commit:
        problems.append(f"verdict commit {actual_commit!r} does not match {expected_commit!r}")

    if problems:
        for problem in problems:
            print(f"release_gate: {problem}", file=sys.stderr)
        return 1

    print(f"release_gate: rehearsal suite green at {expected_commit}")
    return 0


# MARK: - CLI


def parse_arguments(argv):
    parser = argparse.ArgumentParser(prog="release_gate.py", description=__doc__.split("\n\n")[0])
    subparsers = parser.add_subparsers(dest="command", required=True)

    record_parser = subparsers.add_parser("record", help="run the suite and write release evidence")
    record_parser.add_argument("--app", required=True, type=Path, help="a built Yellowhammer.app")
    record_parser.add_argument("--team", required=True, help="the scratch Linear team's key")
    record_parser.add_argument(
        "--evidence-directory", required=True, type=Path,
        help="where suite.log, journals/, night-cards.md and verdict.json are written",
    )
    record_parser.add_argument(
        "--scenario", action="append", type=int, default=None,
        help="a scenario number to run (repeatable; default: every scenario)",
    )
    record_parser.add_argument(
        "--act-timeout", type=float, default=None, help="seconds any single yh invocation may take"
    )

    record_parser.add_argument(
        "--board-connection", dest="installation", metavar="NAME", default=None,
        help="the Board Connection in config.toml, passed to the suite (default: the sole one)",
    )

    check_parser = subparsers.add_parser("check", help="exit 0 only if the evidence is a clean green")
    check_parser.add_argument(
        "--evidence-directory", required=True, type=Path, help="the directory `record` wrote to"
    )
    check_parser.add_argument(
        "--commit", default=None, help="the commit the evidence must match (default: git rev-parse HEAD)"
    )

    return parser.parse_args(argv)


def main(argv=None):
    args = parse_arguments(argv if argv is not None else sys.argv[1:])
    if args.command == "record":
        return record_command(args)
    return check_command(args)


if __name__ == "__main__":
    sys.exit(main())
