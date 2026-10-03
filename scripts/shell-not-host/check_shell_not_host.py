#!/usr/bin/env python3
"""
Shell-not-host verification (P14.9): a Night runs correctly with the app never opened, and with the
app quit mid-Act (system-overview → Yellowhammer app, hard constraint).

Runs two rehearsal Nights, one per rehearsal Project, and compares them:

  1. never-opened  — `yh rehearse --project <A>`, run directly from the app bundle, the way a
                     LaunchAgent runs an Act. The window app must not run at any point during it.
  2. quit-mid-act  — the app is launched, its Recalibrate tab's "Run a Rehearsal Night" is clicked
                     (the app's own detached launch of `yh rehearse --project <B>`), and the app is
                     quit while an Act holds Project B's Act lease. The Night must finish anyway.

Both Nights must finish their land Act, and their Journals and Night Cards must be equivalent once
the values that necessarily differ between two Projects — ids, names, paths, timestamps, generated
identifiers — are normalised away.

Live mode needs two rehearsal Projects configured in ~/.config/yellowhammer, each with its own
scratch Linear project and throwaway Repos, identically seeded and never yet run (no Journal). It
drives the app through System Events, so the terminal running it needs Accessibility permission.

--engine-stub swaps `yh` for a shell stub (the app's `-YellowhammerEngineStub` seam) and a scratch
configuration directory: the harness's own self-test, runnable without Linear. A stub run proves the
harness and the app's detached launch, never the Engine.

Exit codes:
  0 - both Nights finished and are equivalent
  1 - the check failed (a Night failed, the app ran during never-opened, quitting killed the Night,
      or the Journals / Night Cards differ)
  2 - the check could not be set up (bad arguments, missing app, existing Journal, app running)
"""

import argparse
import difflib
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import tomllib
from dataclasses import dataclass
from pathlib import Path

APP_EXECUTABLE_SUFFIX = ".app/Contents/MacOS/Yellowhammer"
# The app's headless launches (`ExceptionNotification.postFlag`, `NotificationPermissionRequest.flag`)
# open no window: `yh` itself launches the app this way to post a notification, so they are not the
# window app opening.
HEADLESS_FLAGS = ("--post-notification", "--request-notification-permission")
LAND_FINISHED = "rehearsal Night: the land Act finished"
ACT_FAILED = re.compile(r"rehearsal Night: the (author|build|land) Act failed")
DEFAULT_CONFIGURATION_DIRECTORY = Path.home() / ".config" / "yellowhammer"

# Clicks through the Recalibrate tab by accessibility identifier (or a tab by its description), waiting
# for each element to appear. argv: <pid> <key>...; a key of "wait:<id>" only waits.
CLICK_SCRIPT = """
function find(proc, key) {
  const wanted = key.startsWith("wait:") ? key.slice(5) : key;
  for (const w of proc.windows()) {
    for (const e of w.entireContents()) {
      try {
        if (wanted.startsWith("tab:")) {
          if (e.role() === "AXRadioButton" && e.description() === wanted.slice(4)) return e;
        } else if (e.attributes.byName("AXIdentifier").value() === wanted) return e;
      } catch (x) {}
    }
  }
  return null;
}
function run(argv) {
  const proc = Application("System Events").processes.whose({unixId: parseInt(argv[0])})[0];
  for (const key of argv.slice(1)) {
    let e = null;
    for (let i = 0; i < 120 && !e; i++) { e = find(proc, key); if (!e) delay(0.25); }
    if (!e) throw new Error("not found: " + key);
    if (!key.startsWith("wait:")) e.click();
  }
  return "ok";
}
"""
RECALIBRATE_CLICKS = [
    "tab:Recalibrate", "recalibrate-run-rehearsal", "recalibrate-confirm-rehearsal",
    "wait:recalibrate-rehearsal-started",
]


class CheckFailed(Exception):
    """The Nights ran, and shell-not-host does not hold."""


class SetupFailed(Exception):
    """The check could not be run at all."""


# MARK: - Processes


@dataclass(frozen=True)
class ProcessRow:
    pid: int
    ppid: int
    args: str


def list_processes():
    output = subprocess.run(
        ["ps", "-axww", "-o", "pid=,ppid=,args="], capture_output=True, text=True, check=True
    ).stdout
    rows = []
    for line in output.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append(ProcessRow(int(parts[0]), int(parts[1]), parts[2]))
    return rows


def is_window_app(args):
    """Whether a process's argument string is the Yellowhammer window app (not a headless launch)."""
    executable = args.split(" -", 1)[0].split(" --", 1)[0]
    if not executable.endswith(APP_EXECUTABLE_SUFFIX):
        return False
    return not any(flag in args.split() for flag in HEADLESS_FLAGS)


def window_apps(processes):
    return [row for row in processes if is_window_app(row.args)]


def rehearse_processes(processes, project_id):
    """`yh rehearse --project <id>` (or the stub's) processes, excluding the `sh -c` wrapper."""
    needle = f"rehearse --project {project_id}"
    return [
        row for row in processes
        if row.args.endswith(needle) and not row.args.startswith("/bin/sh -c")
        and "check_shell_not_host" not in row.args
    ]


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


# MARK: - Configuration


@dataclass(frozen=True)
class ProjectFacts:
    """What necessarily differs between two rehearsal Projects, read from the Project's TOML."""
    id: str
    name: str
    linear_project: str
    paths: tuple  # (path, label) pairs: every Repo path and the Spec Source


def load_project(configuration_directory, project_id):
    for file in sorted((configuration_directory / "projects").glob("*.toml")):
        with file.open("rb") as handle:
            data = tomllib.load(handle)
        if data.get("id") != project_id:
            continue
        paths = [(data.get("spec_source", ""), "<spec source>")]
        for repo in data.get("repos", []):
            paths.append((repo.get("path", ""), f"<repo {repo.get('name', '')}>"))
        expanded = []
        for path, label in paths:
            if path:
                expanded.append((path, label))
                expanded.append((os.path.expanduser(path), label))
        return ProjectFacts(
            id=project_id, name=data.get("name", project_id),
            linear_project=data.get("board", {}).get("linear", {}).get("project", ""),
            paths=tuple(sorted(set(expanded), key=lambda pair: -len(pair[0]))),
        )
    raise SetupFailed(f"no Project with id {project_id!r} in {configuration_directory / 'projects'}")


def journal_path(configuration_directory, project_id):
    return configuration_directory / "journals" / f"{project_id}.db"


# MARK: - Journal equivalence

ISO_TIMESTAMP = re.compile(
    r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?"
)
UUID = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
ISSUE_KEY = re.compile(r"\b[A-Z][A-Z0-9]{1,9}-\d+\b")
GIT_SHA = re.compile(r"\b[0-9a-f]{40}\b")
URL = re.compile(r"https?://[^\s\"'<>)]+")


class Normaliser:
    """Replaces what necessarily differs between two Projects' Nights with stable placeholders.

    Generated identifiers (UUIDs, issue keys, commit SHAs, URLs) become `<kind-N>` in order of first
    appearance, so two equivalent Nights map to the same placeholders and a Night that reuses one
    identifier where the other uses two still shows up as a difference.
    """

    def __init__(self, project):
        self.literals = [(path, label) for path, label in project.paths]
        if project.linear_project:
            self.literals.append((project.linear_project, "<linear project>"))
        if project.name:
            self.literals.append((project.name, "<project name>"))
        self.literals.sort(key=lambda pair: -len(pair[0]))
        self.project_id = re.compile(rf"(?<![\w-]){re.escape(project.id)}(?![\w-])")
        self.aliases = {}

    def _alias(self, kind, value):
        key = (kind, value)
        if key not in self.aliases:
            count = sum(1 for existing in self.aliases if existing[0] == kind)
            self.aliases[key] = f"<{kind}-{count + 1}>"
        return self.aliases[key]

    def text(self, value):
        value = URL.sub(lambda match: self._alias("url", match.group(0)), value)
        for literal, label in self.literals:
            value = value.replace(literal, label)
        value = self.project_id.sub("<project>", value)
        value = ISO_TIMESTAMP.sub("<time>", value)
        value = UUID.sub(lambda match: self._alias("uuid", match.group(0).lower()), value)
        value = GIT_SHA.sub(lambda match: self._alias("sha", match.group(0)), value)
        value = ISSUE_KEY.sub(lambda match: self._alias("key", match.group(0)), value)
        return value

    def value(self, value):
        return self.text(value) if isinstance(value, str) else value


def _tables(connection):
    rows = connection.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' ORDER BY name"
    ).fetchall()
    return [row[0] for row in rows]


def _rows(connection, table):
    quoted = '"' + table.replace('"', '""') + '"'
    columns = [row[1] for row in connection.execute(f"PRAGMA table_info({quoted})")]
    try:
        rows = connection.execute(f"SELECT * FROM {quoted} ORDER BY rowid").fetchall()
    except sqlite3.OperationalError:
        rows = sorted(connection.execute(f"SELECT * FROM {quoted}").fetchall(), key=repr)
    return columns, rows


def open_read_only(path):
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def night_cards(connection, normaliser):
    """The Night Card as the Engine wrote it: each Night's row, and every Board write to its issue."""
    lines = []
    if "night" not in _tables(connection):
        return lines
    columns, nights = _rows(connection, "night")
    for night in nights:
        lines.append("night " + _render(columns, night, normaliser))
    issue_ids = [night[columns.index("night_card_issue_id")] for night in nights
                 if "night_card_issue_id" in columns and night[columns.index("night_card_issue_id")]]
    if "outbox" in _tables(connection):
        outbox_columns, writes = _rows(connection, "outbox")
        for write in writes:
            if write[outbox_columns.index("issue_id")] in issue_ids:
                lines.append("outbox " + _render(outbox_columns, write, normaliser))
    return lines


def journal_dump(connection, normaliser):
    lines = []
    for table in _tables(connection):
        columns, rows = _rows(connection, table)
        lines.append(f"[{table}] {len(rows)} row(s)")
        lines.extend("  " + _render(columns, row, normaliser) for row in rows)
    return lines


def _render(columns, row, normaliser):
    return ", ".join(f"{column}={normaliser.value(value)!r}" for column, value in zip(columns, row))


def snapshot(path, directory):
    """A copy of a finished Night's Journal (and its WAL, if one is left) to read from.

    The Engine's Journal is in WAL mode, and once the last connection closes SQLite removes its `-shm`,
    which a read-only open cannot recreate; the copy is opened read-write instead, so the Journal
    itself is never opened for writing here.
    """
    directory.mkdir(parents=True, exist_ok=True)
    copy = directory / path.name
    shutil.copyfile(path, copy)
    wal = path.with_name(path.name + "-wal")
    if wal.exists():
        shutil.copyfile(wal, copy.with_name(copy.name + "-wal"))
    return copy


def normalised(path, project):
    """The Night Card lines, then the whole Journal, normalised through one Normaliser so that the
    Night Card's placeholders match the ones the Journal dump uses."""
    normaliser = Normaliser(project)
    connection = sqlite3.connect(path)
    try:
        cards = night_cards(connection, normaliser)
        journal = journal_dump(connection, normaliser)
    finally:
        connection.close()
    return cards, journal


def compare(first_label, first, second_label, second):
    """A unified diff of two normalised dumps; empty when equivalent."""
    return list(difflib.unified_diff(first, second, first_label, second_label, lineterm=""))


# MARK: - The two Nights


@dataclass(frozen=True)
class Harness:
    app: Path
    configuration_directory: Path
    stub: Path  # None in live mode
    work_directory: Path
    timeout: float

    @property
    def engine_command(self):
        if self.stub:
            return ["/bin/sh", str(self.stub)]
        return [str(self.app / "Contents" / "MacOS" / "yh")]

    @property
    def environment(self):
        environment = dict(os.environ)
        if self.stub:
            environment["YH_STUB_CONFIGURATION_DIRECTORY"] = str(self.configuration_directory)
        return environment

    def rehearsal_log(self, project_id):
        # SetupEngine.rehearsalLogURL: next to the stub under the stub seam, else the user's Logs.
        if self.stub:
            return self.stub.parent / f"{project_id}.rehearse.log"
        return Path.home() / "Library" / "Logs" / "Yellowhammer" / f"{project_id}.rehearse.log"


def log(message):
    print(f"shell-not-host: {message}", flush=True)


def run_never_opened(harness, project_id):
    """Night A: `yh rehearse` run directly, with the window app never running at any point."""
    output_path = harness.work_directory / f"{project_id}.never-opened.log"
    log(f"never-opened: running rehearse --project {project_id} with the app never launched")
    with output_path.open("w") as output:
        process = subprocess.Popen(
            harness.engine_command + ["rehearse", "--project", project_id],
            stdout=output, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=harness.environment,
        )
        deadline = time.monotonic() + harness.timeout
        while process.poll() is None:
            opened = window_apps(list_processes())
            if opened:
                process.kill()
                raise CheckFailed(f"never-opened: the app ran during the Night: {opened[0].args}")
            if time.monotonic() > deadline:
                process.kill()
                raise CheckFailed(f"never-opened: the Night did not finish within {harness.timeout:.0f}s")
            time.sleep(0.1)
    text = output_path.read_text()
    if process.returncode != 0 or LAND_FINISHED not in text:
        raise CheckFailed(
            f"never-opened: the Night did not finish (exit {process.returncode}); see {output_path}\n{text}"
        )
    log("never-opened: the Night finished its land Act")


def held_act(path):
    """The Act holding the Journal's Act lease right now, or None (also while the Journal cannot be read
    yet: a read-only open of a WAL Journal needs the `-shm` its open writer keeps)."""
    if not path.exists():
        return None
    try:
        with open_read_only(path) as connection:
            row = connection.execute("SELECT act FROM act_lease WHERE id = 1").fetchone()
    except sqlite3.Error:
        return None
    return row[0] if row else None


def launch_app(harness):
    arguments = ["-ApplePersistenceIgnoreState", "YES"]
    environment = []
    if harness.stub:
        arguments += [
            "-YellowhammerConfigurationDirectory", str(harness.configuration_directory),
            "-YellowhammerEngineStub", str(harness.stub),
        ]
        environment = ["--env", f"YH_STUB_CONFIGURATION_DIRECTORY={harness.configuration_directory}"]
    subprocess.run(["open", "-n", "-a", str(harness.app), *environment, "--args", *arguments], check=True)
    deadline = time.monotonic() + 30
    executable = str(harness.app / "Contents" / "MacOS" / "Yellowhammer")
    while time.monotonic() < deadline:
        for row in window_apps(list_processes()):
            if row.args.startswith(executable):
                return row.pid
        time.sleep(0.2)
    raise SetupFailed("the app did not launch within 30s")


def quit_app(harness, pid):
    subprocess.run(
        ["osascript", "-e", f'tell application "{harness.app}" to quit'], capture_output=True, check=False
    )
    deadline = time.monotonic() + 30
    while pid_alive(pid):
        if time.monotonic() > deadline:
            raise SetupFailed(f"the app (pid {pid}) did not quit within 30s")
        time.sleep(0.1)


def run_quit_mid_act(harness, project_id):
    """Night B: launched from the app's Recalibrate tab; the app is quit while an Act holds the lease."""
    rehearsal_log = harness.rehearsal_log(project_id)
    offset = rehearsal_log.stat().st_size if rehearsal_log.exists() else 0
    journal = journal_path(harness.configuration_directory, project_id)

    log(f"quit-mid-act: launching the app and starting a rehearsal Night for {project_id} from Recalibrate")
    app_pid = launch_app(harness)
    try:
        subprocess.run(
            ["open", "-a", str(harness.app), f"yellowhammer://project/{project_id}"], check=True
        )
        clicked = subprocess.run(
            ["osascript", "-l", "JavaScript", "-e", CLICK_SCRIPT, str(app_pid), *RECALIBRATE_CLICKS],
            capture_output=True, text=True,
        )
        if clicked.returncode != 0:
            raise SetupFailed(
                "could not drive the Recalibrate tab (does this terminal have Accessibility permission?): "
                + clicked.stderr.strip()
            )

        deadline = time.monotonic() + harness.timeout
        act = None
        while act is None:
            if time.monotonic() > deadline:
                raise CheckFailed("quit-mid-act: no Act took the Act lease before the timeout")
            act = held_act(journal)
            if act is None:
                time.sleep(0.05)
        night = rehearse_processes(list_processes(), project_id)
        if not night:
            raise CheckFailed("quit-mid-act: the Act lease is held but no rehearse process was found")

        log(f"quit-mid-act: the {act} Act holds the lease; quitting the app")
        quit_app(harness, app_pid)
        app_pid = None
    finally:
        if app_pid is not None and pid_alive(app_pid):
            quit_app(harness, app_pid)

    survivors = [row for row in night if pid_alive(row.pid)]
    if not survivors:
        raise CheckFailed("quit-mid-act: quitting the app killed the Night")
    log(f"quit-mid-act: the Night (pid {survivors[0].pid}) outlived the app; waiting for it to finish")

    deadline = time.monotonic() + harness.timeout
    while any(pid_alive(row.pid) for row in survivors):
        if time.monotonic() > deadline:
            raise CheckFailed(f"quit-mid-act: the Night did not finish within {harness.timeout:.0f}s")
        time.sleep(0.2)
    with rehearsal_log.open() as handle:
        handle.seek(offset)
        text = handle.read()
    (harness.work_directory / f"{project_id}.quit-mid-act.log").write_text(text)
    if LAND_FINISHED not in text:
        failed = ACT_FAILED.search(text)
        reason = f"the {failed.group(1)} Act failed" if failed else "it never finished its land Act"
        raise CheckFailed(f"quit-mid-act: {reason}; see {rehearsal_log}\n{text}")
    log("quit-mid-act: the Night finished its land Act")


# MARK: - Main


def prepare_stub(stub_source, work_directory):
    """Copies the stub into the work directory: under the stub seam the app writes the rehearsal log
    next to the stub, which must not be inside the repository."""
    stub = work_directory / "stub-yh.sh"
    shutil.copyfile(stub_source, stub)
    return stub


def parse_arguments(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--app", required=True, type=Path, help="the built Yellowhammer.app")
    parser.add_argument("--never-opened", required=True, metavar="PROJECT",
                        help="the rehearsal Project whose Night runs with the app never launched")
    parser.add_argument("--quit-mid-act", required=True, metavar="PROJECT",
                        help="the rehearsal Project whose Night is started from the app, then the app quit")
    parser.add_argument("--configuration-directory", type=Path, default=DEFAULT_CONFIGURATION_DIRECTORY,
                        help="only with --engine-stub: yh itself always reads ~/.config/yellowhammer")
    parser.add_argument("--engine-stub", type=Path,
                        help="run the harness self-test against this stub instead of yh")
    parser.add_argument("--timeout", type=float, default=1800, help="seconds each Night may take")
    parser.add_argument("--work-directory", type=Path, help="where logs and dumps go (default: a temp dir)")
    return parser.parse_args(argv)


def build_harness(arguments):
    if arguments.never_opened == arguments.quit_mid_act:
        raise SetupFailed("the two Nights need two different rehearsal Projects")
    if not arguments.engine_stub and arguments.configuration_directory != DEFAULT_CONFIGURATION_DIRECTORY:
        raise SetupFailed("--configuration-directory needs --engine-stub: yh reads ~/.config/yellowhammer")
    app = arguments.app.resolve()
    if not (app / "Contents" / "MacOS" / "yh").is_file():
        raise SetupFailed(f"{app} is not a built Yellowhammer.app with yh in Contents/MacOS")
    configuration_directory = arguments.configuration_directory.expanduser().resolve()
    for project_id in (arguments.never_opened, arguments.quit_mid_act):
        if journal_path(configuration_directory, project_id).exists():
            raise SetupFailed(
                f"{project_id} already has a Journal: both Nights must start from a fresh rehearsal Project"
            )
    running = window_apps(list_processes())
    if running:
        raise SetupFailed(f"quit the Yellowhammer app first (pid {running[0].pid})")
    work_directory = arguments.work_directory or Path(tempfile.mkdtemp(prefix="yh-shell-not-host-"))
    work_directory = work_directory.resolve()
    work_directory.mkdir(parents=True, exist_ok=True)
    stub = None
    if arguments.engine_stub:
        stub = prepare_stub(arguments.engine_stub.resolve(), work_directory)
    return Harness(app, configuration_directory, stub, work_directory, arguments.timeout)


def verify_equivalence(harness, first_id, second_id):
    first_project = load_project(harness.configuration_directory, first_id)
    second_project = load_project(harness.configuration_directory, second_id)
    snapshots = harness.work_directory / "journals"
    first_cards, first_journal = normalised(
        snapshot(journal_path(harness.configuration_directory, first_id), snapshots), first_project
    )
    second_cards, second_journal = normalised(
        snapshot(journal_path(harness.configuration_directory, second_id), snapshots), second_project
    )
    for name, lines in (("never-opened", first_cards + [""] + first_journal),
                        ("quit-mid-act", second_cards + [""] + second_journal)):
        (harness.work_directory / f"{name}.normalised.txt").write_text("\n".join(lines) + "\n")

    if not first_cards:
        raise CheckFailed("never-opened: the Journal records no Night")
    card_diff = compare("never-opened Night Card", first_cards, "quit-mid-act Night Card", second_cards)
    journal_diff = compare("never-opened Journal", first_journal, "quit-mid-act Journal", second_journal)
    if card_diff or journal_diff:
        raise CheckFailed("the two Nights differ:\n" + "\n".join(card_diff + journal_diff))
    log(f"equivalent: {len(first_cards)} Night Card line(s), {len(first_journal)} Journal line(s)")


def main(argv=None):
    arguments = parse_arguments(argv if argv is not None else sys.argv[1:])
    try:
        harness = build_harness(arguments)
        log(f"work directory: {harness.work_directory}")
        if harness.stub:
            log("engine stub: this self-test proves the harness and the app's launch, not the Engine")
        run_never_opened(harness, arguments.never_opened)
        run_quit_mid_act(harness, arguments.quit_mid_act)
        verify_equivalence(harness, arguments.never_opened, arguments.quit_mid_act)
    except SetupFailed as error:
        print(f"shell-not-host: cannot run: {error}", file=sys.stderr)
        return 2
    except CheckFailed as error:
        print(f"shell-not-host: FAILED: {error}", file=sys.stderr)
        return 1
    log("PASSED: both Nights completed identically")
    return 0


if __name__ == "__main__":
    sys.exit(main())
