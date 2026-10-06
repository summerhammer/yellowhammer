#!/usr/bin/env python3
"""
Scratch Linear environment cleanup/verification (P15.1).

Rehearsal Nights run against one scratch Linear team shared by every rehearsing Project, and one
scratch Linear project per Project, all inside a scratch Linear workspace (never production) — see
`scripts/scratch-linear/README.md` for the runbook and `doc/linear-identity-runbook.md` for how the
scratch app's credential gets into the Keychain.

This tool never provisions anything (workflow states, labels, label groups, Linear projects, the
team) — that is `Engine.BoardProvisioner`, run through `yh setup`. The only mutation this tool may
ever send is the `issueArchive` mutation. No workflowState, label, project, team or comment mutation
is ever sent.

Subcommands:

  check --team KEY [--project ID ...]
    Read-only. Verifies the scratch team exists, and that every named Project's (or every Project
    under the configuration directory, if none are named) Linear project resolves and belongs to
    exactly the scratch team — a Linear project shared with, or living in, any other team is a FAIL,
    since that is what keeps a production Linear project safe from this tool. Also reports, per
    Project, the informational count of non-archived issues.
    A Project whose `[board.linear] connection` is not the resolved installation is a FAIL: it
    lives in another workspace and this token cannot see it.
    Exit codes: 0 every check passed, 1 some check failed, 2 the check could not be set up.

  reset --team KEY --project ID [--project ID ...] [--dry-run] [--keep-journal]
    Archives every non-archived issue in each named Project's Linear project, then (unless
    --keep-journal) deletes that Project's Journal. `--project` is required — there is no "reset
    every Project" default. Every Project is guarded before any Project is touched: if any Project
    fails a guard (its Linear project file is missing or incomplete, its Linear project is outside
    the scratch team, its `[board.linear] connection` is not the resolved installation, or its Journal's Act lease has not expired — a Night is running), nothing is
    changed anywhere and the tool exits 2. `--dry-run` reports what would happen and sends no
    mutation and deletes nothing.
    Exit codes: 0 success, 1 a write failed, 2 a setup or guard error (nothing was changed).

Credentials (P17.8: the Board Connection replaces the withdrawn `client_credentials` identity):
this tool never calls the Linear token endpoint and never writes the Keychain. The machine file
`config.toml` declares zero or more named Board Connections under
`[board.linear.connections.<name>]`, each with a required `credential` (`keychain:<account>`),
`workspace` and `yellowhammer_identity`, and an optional `operator`. The global `--board-connection NAME` picks one;
without it the sole declared installation is used (none, or several without the flag, is a
refusal). The tool reads that installation's token pair from the Keychain item `security
find-generic-password -s dev.yellowhammer -a <account> -w`, and uses its `access_token` when more
than two hours remain before `expires_at`. Otherwise it runs `yh doctor --check linear --json`,
which refreshes the pair under that installation's lock, then re-reads the Keychain item once.
Still stale or missing after that: "no working Linear installation on this Mac; run yh setup
--install-linear". A Project names its installation in `[board.linear] connection`; reset and
check refuse a Project on any other installation.
The token is never printed anywhere, including error messages.
"""

import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

GRAPHQL_URL = "https://api.linear.app/graphql"
#: `yh` refreshes ahead of an Act's first Linear call when less than this remains (spec: "Keeping
#: it alive"); this tool refreshes on the same margin rather than risking a 401 mid-run.
TOKEN_STALE_MARGIN = timedelta(hours=2)
DEFAULT_CONFIGURATION_DIRECTORY = Path.home() / ".config" / "yellowhammer"
PROJECT_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")
MAX_ARCHIVE_PASSES = 5


class SetupFailed(Exception):
    """The tool could not be set up, or a reset guard refused: nothing was changed."""


class RunFailed(Exception):
    """A write did not converge (an archive pass exhausted its cap)."""


class ProjectError(Exception):
    """A Project's configuration is missing or incomplete."""


class LinearError(Exception):
    """A GraphQL request returned `errors`, or the response could not be parsed."""


# MARK: - Transport


class HTTPTransport:
    """The real network transport: POSTs form data (the OAuth token endpoint) or JSON (GraphQL)."""

    def post_form(self, url, fields):
        body = urllib.parse.urlencode(fields).encode()
        request = urllib.request.Request(
            url, data=body, method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        return self._send(request)

    def post_json(self, url, payload, headers=None):
        body = json.dumps(payload).encode()
        full_headers = {"Content-Type": "application/json"}
        full_headers.update(headers or {})
        request = urllib.request.Request(url, data=body, method="POST", headers=full_headers)
        return self._send(request)

    @staticmethod
    def _send(request):
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, response.read().decode()
        except urllib.error.HTTPError as error:
            return error.code, error.read().decode()


def keychain_secret(account):
    """Reads a secret from the login keychain item `service = dev.yellowhammer`, `account` — a
    plain string secret (e.g. the rehearsal Operator's own credential), not the Installation's
    token pair; see `keychain_token_pair` for that."""
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "dev.yellowhammer", "-a", account, "-w"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise SetupFailed(f"could not read the Linear credential from the Keychain (account {account!r})")
    return result.stdout.strip()


def keychain_token_pair(account):
    """Reads and parses the Installation's token pair JSON (`access_token`, `refresh_token`,
    `expires_at`) from the Keychain item `account`. `None` when absent or unparseable — never
    raises, so callers can fall through to a refresh."""
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "dev.yellowhammer", "-a", account, "-w"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout.strip())
    except json.JSONDecodeError:
        return None


def _fresh_access_token(pair, now):
    """The pair's `access_token`, or `None` when the pair is absent, malformed, or fewer than
    `TOKEN_STALE_MARGIN` remain before `expires_at`."""
    if not pair:
        return None
    token = pair.get("access_token")
    expires_at = pair.get("expires_at")
    if not token or not expires_at:
        return None
    try:
        expiry = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
    except ValueError:
        return None
    if expiry - now <= TOKEN_STALE_MARGIN:
        return None
    return token


def resolve_yh_path(args):
    """`--yh`, else `$YH_PATH`, else whatever `yh` resolves to on `PATH` — the same fallback
    order `suite_env.py` uses via its own `env.yh_executable`."""
    if getattr(args, "yh", None):
        return Path(args.yh)
    env = os.environ.get("YH_PATH")
    if env:
        return Path(env)
    which = shutil.which("yh")
    if which:
        return Path(which)
    raise SetupFailed("no yh executable found: pass --yh, set YH_PATH, or put yh on PATH")


def resolve_access_token(configuration_directory, machine, yh_path_getter, *,
                          keychain_reader=keychain_token_pair, now=None):
    """The Installation's access token: read from the Keychain, refreshed once (through `yh doctor
    --check linear --json`, under the machine-wide lock) when fewer than two hours remain.
    `yh_path_getter` is a zero-argument callable, so resolving `yh`'s path never happens unless a
    refresh is actually needed."""
    now = now or datetime.now(timezone.utc)
    account = parse_credential_reference(machine.credential)
    token = _fresh_access_token(keychain_reader(account), now)
    if token:
        return token
    yh_path = yh_path_getter()
    subprocess.run([str(yh_path), "doctor", "--check", "linear", "--json"], capture_output=True, text=True)
    token = _fresh_access_token(keychain_reader(account), now)
    if not token:
        raise SetupFailed("no working Linear installation on this Mac; run yh setup --install-linear")
    return token


# MARK: - Linear client


class LinearClient:
    """Sends GraphQL requests with an already-resolved Installation access token. No OAuth flow of
    its own: the token comes from `resolve_access_token`, which reads it from the Keychain."""

    def __init__(self, transport, access_token, *, graphql_url=GRAPHQL_URL, installation_name=None):
        self.installation_name = installation_name
        self._transport = transport
        self._access_token = access_token
        self._graphql_url = graphql_url

    def graphql(self, query, variables=None):
        status, text = self._transport.post_json(
            self._graphql_url, {"query": query, "variables": variables or {}},
            headers={"Authorization": f"Bearer {self._access_token}"},
        )
        try:
            payload = json.loads(text)
        except json.JSONDecodeError as error:
            raise LinearError(f"could not parse the Linear GraphQL response (HTTP {status})") from error
        if payload.get("errors"):
            raise LinearError(f"Linear GraphQL error: {payload['errors']}")
        if status != 200:
            raise LinearError(f"Linear GraphQL request failed (HTTP {status})")
        return payload.get("data") or {}


TEAMS_QUERY = "query($key: String!) { teams(filter: {key: {eq: $key}}) { nodes { id key } } }"
PROJECT_QUERY = "query($id: String!) { project(id: $id) { id name teams { nodes { id key } } } }"
ISSUES_QUERY = """
query($id: ID!, $after: String) {
  issues(filter: {project: {id: {eq: $id}}}, first: 50, after: $after) {
    nodes { id }
    pageInfo { hasNextPage endCursor }
  }
}
"""
ARCHIVE_MUTATION = "mutation($id: String!) { issueArchive(id: $id) { success } }"


def find_team(client, key):
    data = client.graphql(TEAMS_QUERY, {"key": key})
    nodes = data.get("teams", {}).get("nodes", [])
    return nodes[0] if nodes else None


def fetch_linear_project(client, linear_project_id):
    data = client.graphql(PROJECT_QUERY, {"id": linear_project_id})
    return data.get("project")


def list_issue_ids(client, linear_project_id):
    """Every non-archived issue id in the Linear project, paginated with first/after."""
    ids = []
    after = None
    while True:
        data = client.graphql(ISSUES_QUERY, {"id": linear_project_id, "after": after})
        connection = data["issues"]
        ids.extend(node["id"] for node in connection["nodes"])
        page_info = connection["pageInfo"]
        if not page_info["hasNextPage"]:
            return ids
        after = page_info["endCursor"]


def archive_issue(client, issue_id):
    """Sends the one mutation this tool ever sends. Returns whether Linear reported success."""
    data = client.graphql(ARCHIVE_MUTATION, {"id": issue_id})
    return bool(data.get("issueArchive", {}).get("success"))


# MARK: - Configuration


@dataclass(frozen=True)
class MachineConfig:
    """One Board Connection from `[board.linear.connections.<name>]`."""

    name: str
    credential: str
    workspace: str | None = None
    app_user: str | None = None
    operator: str | None = None


def load_machine_config(configuration_directory, installation=None):
    """The named Board Connection, or the sole one when `installation` is None."""
    path = configuration_directory / "config.toml"
    entries = {}
    if path.is_file():
        with path.open("rb") as handle:
            data = tomllib.load(handle)
        entries = data.get("board", {}).get("linear", {}).get("connections", {})
    if installation is not None:
        if installation not in entries:
            registered = ", ".join(sorted(entries)) or "none"
            raise SetupFailed(
                f"no Linear installation named {installation!r} in config.toml (registered: {registered})"
            )
        name = installation
    elif not entries:
        raise SetupFailed("no Linear installation in config.toml; run yh setup --install-linear")
    elif len(entries) > 1:
        raise SetupFailed(
            f"config.toml has several Linear installations ({', '.join(sorted(entries))}); "
            "pass --board-connection <name>"
        )
    else:
        name = next(iter(entries))
    entry = entries[name]
    credential = entry.get("credential")
    if not credential:
        raise SetupFailed(f"Linear installation {name!r} has no credential in config.toml")
    return MachineConfig(
        name=name,
        credential=credential,
        workspace=entry.get("workspace"),
        app_user=entry.get("yellowhammer_identity"),
        operator=entry.get("operator"),
    )


def parse_credential_reference(raw):
    prefix = "keychain:"
    if not raw.startswith(prefix) or len(raw) <= len(prefix):
        raise SetupFailed(f"unsupported credential reference {raw!r}; only keychain:<account> is supported")
    return raw[len(prefix):]


def build_client(configuration_directory, args, transport, *, keychain_reader=keychain_token_pair):
    machine = load_machine_config(configuration_directory, getattr(args, "installation", None))
    token = resolve_access_token(
        configuration_directory, machine, lambda: resolve_yh_path(args), keychain_reader=keychain_reader
    )
    return LinearClient(transport, token, installation_name=machine.name)


def project_file_path(configuration_directory, project_id):
    return configuration_directory / "projects" / f"{project_id}.toml"


def _load_board_linear(configuration_directory, project_id):
    path = project_file_path(configuration_directory, project_id)
    if not path.is_file():
        raise ProjectError(f"no Project file at {path}")
    with path.open("rb") as handle:
        data = tomllib.load(handle)
    return data.get("board", {}).get("linear", {})


def load_linear_project_id(configuration_directory, project_id):
    linear_project_id = _load_board_linear(configuration_directory, project_id).get("project")
    if not linear_project_id:
        raise ProjectError(f"Project {project_id!r} has no [board.linear] project")
    return linear_project_id


def load_project_installation(configuration_directory, project_id):
    """The Project's `[board.linear] connection`."""
    installation = _load_board_linear(configuration_directory, project_id).get("connection")
    if not installation:
        raise ProjectError(f"Project {project_id!r} has no [board.linear] connection")
    return installation


def installation_mismatch(configuration_directory, project_id, installation_name):
    """An error message when the Project lives on another installation, else empty. Raises
    ProjectError for a missing or incomplete Project file."""
    project_installation = load_project_installation(configuration_directory, project_id)
    if project_installation != installation_name:
        return (
            f"Project {project_id!r} uses Linear installation {project_installation!r} but this run "
            f"resolved installation {installation_name!r}; that Project lives in another workspace "
            "and must not be touched with this token (pass --board-connection to match)"
        )
    return ""


def default_project_ids(configuration_directory):
    directory = configuration_directory / "projects"
    if not directory.is_dir():
        return []
    return sorted(
        file.stem for file in directory.glob("*.toml") if PROJECT_ID_PATTERN.match(file.stem)
    )


def journal_path(configuration_directory, project_id):
    return configuration_directory / "journals" / f"{project_id}.db"


# MARK: - Journal Act lease guard


def journal_lease_active(configuration_directory, project_id, now=None):
    """Whether the Journal's `act_lease` row (id = 1) is unexpired: a Night is running.

    A Journal with no `act_lease` table or row is fine (never run, or the lease was released).
    Opened read-only through a `file:` URI so this never becomes a second writer.
    """
    path = journal_path(configuration_directory, project_id)
    if not path.exists():
        return False
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        try:
            row = connection.execute("SELECT expires_at FROM act_lease WHERE id = 1").fetchone()
        except sqlite3.OperationalError:
            return False
    finally:
        connection.close()
    if row is None:
        return False
    expires_at = parse_journal_timestamp(row[0])
    now = now or datetime.now(timezone.utc)
    return expires_at > now


def parse_journal_timestamp(text):
    """Parses the Journal's ISO 8601 UTC timestamp (`JournalStore.timestampStyle`, e.g.
    `2026-09-24T12:34:56Z`)."""
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


# MARK: - Guards shared by check and reset


def verify_team_membership(client, linear_project_id, team):
    """Whether the Linear project's teams are exactly `{team}`. Returns (ok, message)."""
    linear_project = fetch_linear_project(client, linear_project_id)
    if linear_project is None:
        return False, f"Linear project {linear_project_id} not found"
    team_ids = {node["id"] for node in linear_project["teams"]["nodes"]}
    if team_ids != {team["id"]}:
        keys = sorted(node.get("key", node["id"]) for node in linear_project["teams"]["nodes"])
        return False, f"Linear project {linear_project_id} belongs to team(s) {keys}, expected only [{team['key']}]"
    return True, ""


def guard_project(client, configuration_directory, project_id, team, installation_name):
    """Every reset guard for one Project. Returns (linear_project_id, error) — error is empty on
    success."""
    try:
        linear_project_id = load_linear_project_id(configuration_directory, project_id)
        mismatch = installation_mismatch(configuration_directory, project_id, installation_name)
    except ProjectError as error:
        return None, str(error)
    if mismatch:
        return None, mismatch
    ok, message = verify_team_membership(client, linear_project_id, team)
    if not ok:
        return None, message
    if journal_lease_active(configuration_directory, project_id):
        return None, f"Project {project_id!r}: a Night is running (the Journal's Act lease has not expired)"
    return linear_project_id, ""


# MARK: - check


def report(ok, message):
    return f"{'PASS' if ok else 'FAIL'} {message}"


def check_command(args, configuration_directory, transport, keychain_reader=keychain_token_pair):
    client = build_client(configuration_directory, args, transport, keychain_reader=keychain_reader)
    installation_name = client.installation_name
    overall_ok = True

    team = None
    try:
        team = find_team(client, args.team)
    except LinearError as error:
        print(report(False, f"team {args.team} exists: could not query Linear ({error})"))
        overall_ok = False
    else:
        if team is None:
            print(report(False, f"team {args.team} exists"))
            overall_ok = False
        else:
            print(report(True, f"team {args.team} exists"))

    project_ids = args.project or default_project_ids(configuration_directory)
    for project_id in project_ids:
        try:
            linear_project_id = load_linear_project_id(configuration_directory, project_id)
            mismatch = installation_mismatch(configuration_directory, project_id, installation_name)
        except ProjectError as error:
            print(report(False, f"Project {project_id}: {error}"))
            overall_ok = False
            continue
        if mismatch:
            print(report(False, f"Project {project_id}: {mismatch}"))
            overall_ok = False
            continue
        try:
            linear_project = fetch_linear_project(client, linear_project_id)
        except LinearError as error:
            print(report(
                False, f"Project {project_id}: could not query Linear project {linear_project_id} ({error})"
            ))
            overall_ok = False
            continue
        if linear_project is None:
            print(report(False, f"Project {project_id}: Linear project {linear_project_id} not found"))
            overall_ok = False
            continue
        team_ids = {node["id"] for node in linear_project["teams"]["nodes"]}
        if team is not None and team_ids != {team["id"]}:
            keys = sorted(node.get("key", node["id"]) for node in linear_project["teams"]["nodes"])
            print(report(
                False,
                f"Project {project_id}: Linear project {linear_project_id} belongs to team(s) {keys}, "
                f"expected only [{args.team}]",
            ))
            overall_ok = False
        else:
            print(report(
                True, f"Project {project_id}: resolves to Linear project {linear_project_id}, in only team {args.team}"
            ))
        try:
            count = len(list_issue_ids(client, linear_project_id))
            print(f"INFO Project {project_id}: {count} non-archived issue(s) in {linear_project_id}")
        except LinearError as error:
            print(f"INFO Project {project_id}: could not count issues ({error})")

    return 0 if overall_ok else 1


# MARK: - reset


def archive_until_empty(client, linear_project_id):
    """Archives every non-archived issue, re-listing after each pass to tolerate issues Linear
    auto-archived alongside a parent. Raises RunFailed if issues remain after the pass cap."""
    ids = list_issue_ids(client, linear_project_id)
    if not ids:
        return 0
    total = len(ids)
    for _ in range(MAX_ARCHIVE_PASSES):
        for issue_id in ids:
            try:
                archive_issue(client, issue_id)
            except LinearError:
                pass  # tolerated here; the re-list below decides whether it actually persists
        ids = list_issue_ids(client, linear_project_id)
        if not ids:
            return total
    raise RunFailed(
        f"{len(ids)} issue(s) in Linear project {linear_project_id} were still listed "
        f"after {MAX_ARCHIVE_PASSES} archive passes"
    )


def handle_journal(configuration_directory, project_id, keep):
    path = journal_path(configuration_directory, project_id)
    if keep:
        return "kept"
    if not path.exists():
        return "none"
    for suffix in ("", "-wal", "-shm"):
        candidate = configuration_directory / "journals" / f"{project_id}.db{suffix}"
        if candidate.exists():
            candidate.unlink()
    return "removed"


def reset_command(args, configuration_directory, transport, keychain_reader=keychain_token_pair):
    client = build_client(configuration_directory, args, transport, keychain_reader=keychain_reader)
    installation_name = client.installation_name
    team = find_team(client, args.team)
    if team is None:
        raise SetupFailed(f"no Linear team with key {args.team!r}")

    resolved = {}
    guard_failures = []
    for project_id in args.project:
        linear_project_id, message = guard_project(
            client, configuration_directory, project_id, team, installation_name
        )
        if message:
            guard_failures.append(f"{project_id}: {message}")
        else:
            resolved[project_id] = linear_project_id
    if guard_failures:
        raise SetupFailed("refusing to reset; nothing was changed:\n  " + "\n  ".join(guard_failures))

    failed = False
    for project_id in args.project:
        linear_project_id = resolved[project_id]
        if args.dry_run:
            ids = list_issue_ids(client, linear_project_id)
            if ids:
                print(f"reset: {project_id}: would archive {len(ids)} issue(s) (dry-run)")
            else:
                print(f"reset: {project_id}: nothing to archive (dry-run)")
            print(f"reset: {project_id}: Journal untouched (dry-run)")
            continue
        try:
            archived = archive_until_empty(client, linear_project_id)
        except RunFailed as error:
            print(f"reset: {project_id}: FAILED: {error}", file=sys.stderr)
            failed = True
            continue
        if archived:
            print(f"reset: {project_id}: archived {archived} issue(s)")
        else:
            print(f"reset: {project_id}: nothing to archive")
        journal_status = handle_journal(configuration_directory, project_id, keep=args.keep_journal)
        print(f"reset: {project_id}: Journal {journal_status}")

    return 1 if failed else 0


# MARK: - Main


def project_id_type(value):
    if not PROJECT_ID_PATTERN.match(value):
        raise argparse.ArgumentTypeError(f"invalid Project id {value!r}; must match [A-Za-z0-9_-]+")
    return value


def parse_arguments(argv):
    parser = argparse.ArgumentParser(prog="scratch_linear.py", description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--configuration-directory", type=Path, default=DEFAULT_CONFIGURATION_DIRECTORY,
        help="default ~/.config/yellowhammer",
    )
    parser.add_argument(
        "--board-connection", dest="installation", metavar="NAME", default=None,
        help="the Board Connection (a name under [board.linear.connections] in config.toml); "
        "default: the sole one",
    )
    parser.add_argument(
        "--yh", help="the yh executable, for a refresh (`doctor --check linear --json`) "
        "when the Keychain's access token is stale (else $YH_PATH, else PATH)",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    check_parser = subparsers.add_parser("check", help="read-only: verify the scratch team and Projects")
    check_parser.add_argument("--team", required=True, help="the scratch Linear team's key")
    check_parser.add_argument(
        "--project", action="append", type=project_id_type, default=None,
        help="a Project id to check (default: every Project under the configuration directory)",
    )

    reset_parser = subparsers.add_parser(
        "reset", help="archive a Project's scratch issues and remove its Journal between rehearsal runs"
    )
    reset_parser.add_argument("--team", required=True, help="the scratch Linear team's key")
    reset_parser.add_argument(
        "--project", action="append", type=project_id_type, required=True,
        help="a Project id to reset; required, repeatable, no default",
    )
    reset_parser.add_argument(
        "--dry-run", action="store_true", help="report what would happen; send no mutation, delete nothing"
    )
    reset_parser.add_argument(
        "--keep-journal", action="store_true", help="archive issues but keep the Project's Journal"
    )

    return parser.parse_args(argv)


def main(argv=None):
    args = parse_arguments(argv if argv is not None else sys.argv[1:])
    configuration_directory = args.configuration_directory.expanduser().resolve()
    transport = HTTPTransport()
    try:
        if args.command == "check":
            return check_command(args, configuration_directory, transport)
        return reset_command(args, configuration_directory, transport)
    except SetupFailed as error:
        print(f"scratch-linear: cannot run: {error}", file=sys.stderr)
        return 2
    except LinearError as error:
        print(f"scratch-linear: failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
