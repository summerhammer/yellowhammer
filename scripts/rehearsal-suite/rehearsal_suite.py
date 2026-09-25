#!/usr/bin/env python3
"""
Rehearsal scenario suite (P15.3): runs scripted end-to-end rehearsal Nights against a built
`Yellowhammer.app` and asserts only what a rehearsal Night may be asserted against. See
`README.md` for the full contract, the Prerequisites, and what each of the 13 scenarios checks.

  run --app PATH --team KEY [--scenario N ...] [--root DIR] [--work-directory DIR]
      [--configuration-directory DIR] [--act-timeout SECONDS]
    Runs the selected scenarios (default: all). Exit codes: 0 every selected scenario passed,
    1 a scenario failed, 2 the suite could not be set up (nothing was run).

  list
    Prints every scenario's number, title, and whether it needs the Operator credential.

This tool never runs `yh` outside `author`/`build`/`land`/`rehearse`/`validate`/`setup --init`
against `--rehearsal` Nights, never dispatches an agent CLI, never pushes, and never opens a
pull request — the Acts it drives stop at those boundaries themselves.
"""

import argparse
import sys
import tempfile
from pathlib import Path

import scenarios
import suite_env


class ChecksRecorder:
    """Records PASS/FAIL for one scenario, printing each line as it happens."""

    def __init__(self, scenario_number, title):
        self.scenario_number = scenario_number
        self.title = title
        self.results = []

    def expect(self, condition, message):
        ok = bool(condition)
        self.results.append((ok, message))
        print(f"{'PASS' if ok else 'FAIL'} [{self.scenario_number}] {message}", flush=True)
        return ok

    def require(self, condition, message):
        ok = self.expect(condition, message)
        if not ok:
            raise AbortScenario(message)
        return ok

    @property
    def passed(self):
        return all(ok for ok, _ in self.results)

    @property
    def failures(self):
        return [message for ok, message in self.results if not ok]


class AbortScenario(Exception):
    """Raised by `ChecksRecorder.require` on failure; ends the scenario, not the suite."""


def run_scenario(env, spec):
    checks = ChecksRecorder(spec.number, spec.title)
    print(f"=== Scenario {spec.number}: {spec.title} ===", flush=True)
    try:
        spec.func(env, checks)
    except AbortScenario:
        pass
    except Exception as error:  # noqa: BLE001 - an unexpected exception is a FAIL, not a crash
        checks.expect(False, f"unexpected exception: {error!r}")
    return checks


def print_summary(all_checks):
    print("\n=== Summary ===")
    overall_ok = True
    for checks in all_checks:
        status = "PASS" if checks.passed else "FAIL"
        if not checks.passed:
            overall_ok = False
        print(f"{status} [{checks.scenario_number}] {checks.title}")
        for message in checks.failures:
            print(f"    FAIL: {message}")
    return overall_ok


def selected_scenario_numbers(args):
    if args.scenario:
        unknown = set(args.scenario) - set(scenarios.SCENARIOS)
        if unknown:
            raise suite_env.SetupFailed(f"unknown scenario number(s): {sorted(unknown)}")
        return sorted(set(args.scenario))
    return sorted(scenarios.SCENARIOS)


def run_command(args):
    numbers = selected_scenario_numbers(args)
    root = args.root.expanduser().resolve()
    configuration_directory = args.configuration_directory.expanduser().resolve()
    work_directory = args.work_directory
    if work_directory is None:
        work_directory = Path(tempfile.mkdtemp(prefix="yh-rehearsal-suite-"))
    else:
        work_directory = work_directory.expanduser().resolve()
        work_directory.mkdir(parents=True, exist_ok=True)
    print(f"rehearsal-suite: work directory: {work_directory}")

    app = args.app.expanduser().resolve()
    env = suite_env.make_environment(
        app=app, team=args.team, root=root, work_directory=work_directory,
        configuration_directory=configuration_directory, act_timeout=args.act_timeout,
    )

    try:
        suite_env.preflight(env, set(numbers))
        for project_id in suite_env.SUITE_PROJECTS:
            suite_env.ensure_project(env, project_id)
    except suite_env.SetupFailed as error:
        print(f"rehearsal-suite: cannot run: {error}", file=sys.stderr)
        return 2

    all_checks = [run_scenario(env, scenarios.SCENARIOS[number]) for number in numbers]
    overall_ok = print_summary(all_checks)
    project_ids = ", ".join(suite_env.SUITE_PROJECTS)
    print(
        f"\nrehearsal-suite: {project_ids} remain installed in {configuration_directory / 'projects'}/ "
        "— `yh setup --install-jobs` would schedule real Nights for them; "
        "`rehearsal_suite.py teardown` removes them."
    )
    return 0 if overall_ok else 1


def teardown_command(args):
    root = args.root.expanduser().resolve()
    configuration_directory = args.configuration_directory.expanduser().resolve()
    work_directory = args.work_directory
    if work_directory is None:
        work_directory = Path(tempfile.mkdtemp(prefix="yh-rehearsal-suite-teardown-"))
    else:
        work_directory = work_directory.expanduser().resolve()
        work_directory.mkdir(parents=True, exist_ok=True)
    print(f"rehearsal-suite teardown: work directory: {work_directory}")

    app = args.app.expanduser().resolve()
    env = suite_env.make_environment(
        app=app, team=args.team, root=root, work_directory=work_directory,
        configuration_directory=configuration_directory, act_timeout=600.0,
    )

    try:
        overall_ok, per_project_results = suite_env.teardown(env, dry_run=args.dry_run)
    except suite_env.SetupFailed as error:
        print(f"rehearsal-suite teardown: cannot run: {error}", file=sys.stderr)
        return 2

    print("\n=== Teardown summary ===")
    for project_id, ok, messages in per_project_results:
        print(f"{'PASS' if ok else 'FAIL'} {project_id}")
        for message in messages:
            print(f"    {message}")
    return 0 if overall_ok else 1


def list_command(args):
    for number in sorted(scenarios.SCENARIOS):
        spec = scenarios.SCENARIOS[number]
        operator_note = " (needs the Operator credential)" if spec.needs_operator else ""
        print(f"{number}. {spec.title}{operator_note}")
    return 0


def parse_arguments(argv):
    parser = argparse.ArgumentParser(prog="rehearsal_suite.py", description=__doc__.split("\n\n")[0])
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="run the suite (or a subset of scenarios)")
    run_parser.add_argument("--app", required=True, type=Path, help="a built Yellowhammer.app")
    run_parser.add_argument("--team", required=True, help="the scratch Linear team's key")
    run_parser.add_argument(
        "--scenario", action="append", type=int, default=None,
        help="a scenario number to run (repeatable; default: every scenario)",
    )
    run_parser.add_argument(
        "--root", type=Path, default=suite_env.DEFAULT_ROOT,
        help="where fixture trees are built (default: ~/Library/Caches/dev.yellowhammer/rehearsal-suite)",
    )
    run_parser.add_argument(
        "--work-directory", type=Path, default=None,
        help="where logs, yh output and Journal snapshots go (default: a fresh temp dir)",
    )
    run_parser.add_argument(
        "--configuration-directory", type=Path, default=suite_env.DEFAULT_CONFIGURATION_DIRECTORY,
        help="default ~/.config/yellowhammer (yh itself always reads this default)",
    )
    run_parser.add_argument(
        "--act-timeout", type=float, default=600.0, help="seconds any single yh invocation may take"
    )

    subparsers.add_parser("list", help="print every scenario's number, title and Operator need")

    teardown_parser = subparsers.add_parser(
        "teardown", help="remove everything a suite run leaves on the machine (Projects, Linear projects, "
        "Orca ADE registrations, fixture trees)"
    )
    teardown_parser.add_argument("--app", required=True, type=Path, help="a built Yellowhammer.app")
    teardown_parser.add_argument("--team", required=True, help="the scratch Linear team's key")
    teardown_parser.add_argument(
        "--root", type=Path, default=suite_env.DEFAULT_ROOT,
        help="where fixture trees were built (default: ~/Library/Caches/dev.yellowhammer/rehearsal-suite)",
    )
    teardown_parser.add_argument(
        "--configuration-directory", type=Path, default=suite_env.DEFAULT_CONFIGURATION_DIRECTORY,
        help="default ~/.config/yellowhammer (yh itself always reads this default)",
    )
    teardown_parser.add_argument(
        "--work-directory", type=Path, default=None,
        help="where the `yh project remove` log goes (default: a fresh temp dir)",
    )
    teardown_parser.add_argument(
        "--dry-run", action="store_true",
        help="report what would be removed; sends no mutation, deletes nothing",
    )

    return parser.parse_args(argv)


def main(argv=None):
    args = parse_arguments(argv if argv is not None else sys.argv[1:])
    if args.command == "run":
        return run_command(args)
    if args.command == "teardown":
        return teardown_command(args)
    return list_command(args)


if __name__ == "__main__":
    sys.exit(main())
