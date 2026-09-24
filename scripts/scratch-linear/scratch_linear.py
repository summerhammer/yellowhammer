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
    Exit codes: 0 every check passed, 1 some check failed, 2 the check could not be set up.

  reset --team KEY --project ID [--project ID ...] [--dry-run] [--keep-journal]
    Archives every non-archived issue in each named Project's Linear project, then (unless
    --keep-journal) deletes that Project's Journal. `--project` is required — there is no "reset
    every Project" default. Every Project is guarded before any Project is touched: if any Project
    fails a guard (its Linear project file is missing or incomplete, its Linear project is outside
    the scratch team, or its Journal's Act lease has not expired — a Night is running), nothing is
    changed anywhere and the tool exits 2. `--dry-run` reports what would happen and sends no
    mutation and deletes nothing.
    Exit codes: 0 success, 1 a write failed, 2 a setup or guard error (nothing was changed).

Credentials: the client id comes from --client-id, else $YH_LINEAR_CLIENT_ID, else
`[linear] client_id` in the machine's `config.toml`. The client secret is read only from the
Keychain, through the `credential` reference in `config.toml` (`keychain:<account>`, default
`keychain:linear`) — never from argv or the environment, and never printed anywhere, including
error messages.
"""

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

TOKEN_URL = "https://api.linear.app/oauth/token"
GRAPHQL_URL = "https://api.linear.app/graphql"
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
    """Reads a secret from the login keychain item `service = dev.yellowhammer`, `account`."""
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "dev.yellowhammer", "-a", account, "-w"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise SetupFailed(f"could not read the Linear credential from the Keychain (account {account!r})")
    return result.stdout.strip()


# MARK: - Linear client


class LinearClient:
    """Obtains a `client_credentials` token on first use and sends GraphQL requests with it."""

    def __init__(self, transport, client_id, secret, *, token_url=TOKEN_URL, graphql_url=GRAPHQL_URL):
        self._transport = transport
        self._client_id = client_id
        self._secret = secret
        self._token_url = token_url
        self._graphql_url = graphql_url
        self._token = None

    def _ensure_token(self):
        if self._token is not None:
            return self._token
        status, text = self._transport.post_form(self._token_url, {
            "client_id": self._client_id,
            "client_secret": self._secret,
            "grant_type": "client_credentials",
            "scope": "read,write",
        })
        if status != 200:
            raise SetupFailed(f"could not obtain a Linear access token (HTTP {status})")
        try:
            payload = json.loads(text)
        except json.JSONDecodeError as error:
            raise SetupFailed("could not parse the Linear token response") from error
        token = payload.get("access_token")
        if not token:
            raise SetupFailed("the Linear token response had no access_token")
        self._token = token
        return token

    def graphql(self, query, variables=None):
        token = self._ensure_token()
        status, text = self._transport.post_json(
            self._graphql_url, {"query": query, "variables": variables or {}},
            headers={"Authorization": f"Bearer {token}"},
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
    client_id: str | None
    credential: str


def load_machine_config(configuration_directory):
    path = configuration_directory / "config.toml"
    if not path.is_file():
        return MachineConfig(client_id=None, credential="keychain:linear")
    with path.open("rb") as handle:
        data = tomllib.load(handle)
    linear = data.get("linear", {})
    return MachineConfig(
        client_id=linear.get("client_id"), credential=linear.get("credential", "keychain:linear")
    )


def resolve_client_id(args, machine):
    if args.client_id:
        return args.client_id
    env = os.environ.get("YH_LINEAR_CLIENT_ID")
    if env:
        return env
    if machine.client_id:
        return machine.client_id
    raise SetupFailed(
        "no Linear client id: pass --client-id, set YH_LINEAR_CLIENT_ID, "
        "or set [linear] client_id in config.toml"
    )


def parse_credential_reference(raw):
    prefix = "keychain:"
    if not raw.startswith(prefix) or len(raw) <= len(prefix):
        raise SetupFailed(f"unsupported credential reference {raw!r}; only keychain:<account> is supported")
    return raw[len(prefix):]


def build_client(configuration_directory, args, transport, secret_reader):
    machine = load_machine_config(configuration_directory)
    client_id = resolve_client_id(args, machine)
    account = parse_credential_reference(machine.credential)
    secret = secret_reader(account)
    return LinearClient(transport, client_id, secret)


def project_file_path(configuration_directory, project_id):
    return configuration_directory / "projects" / f"{project_id}.toml"


def load_linear_project_id(configuration_directory, project_id):
    path = project_file_path(configuration_directory, project_id)
    if not path.is_file():
        raise ProjectError(f"no Project file at {path}")
    with path.open("rb") as handle:
        data = tomllib.load(handle)
    linear_project_id = data.get("linear_project")
    if not linear_project_id:
        raise ProjectError(f"Project {project_id!r} has no linear_project")
    return linear_project_id


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


def guard_project(client, configuration_directory, project_id, team):
    """Every reset guard for one Project. Returns (linear_project_id, error) — error is empty on
    success."""
    try:
        linear_project_id = load_linear_project_id(configuration_directory, project_id)
    except ProjectError as error:
        return None, str(error)
    ok, message = verify_team_membership(client, linear_project_id, team)
    if not ok:
        return None, message
    if journal_lease_active(configuration_directory, project_id):
        return None, f"Project {project_id!r}: a Night is running (the Journal's Act lease has not expired)"
    return linear_project_id, ""


# MARK: - check


def report(ok, message):
    return f"{'PASS' if ok else 'FAIL'} {message}"


def check_command(args, configuration_directory, transport, secret_reader):
    client = build_client(configuration_directory, args, transport, secret_reader)
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
        except ProjectError as error:
            print(report(False, f"Project {project_id}: {error}"))
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


def reset_command(args, configuration_directory, transport, secret_reader):
    client = build_client(configuration_directory, args, transport, secret_reader)
    team = find_team(client, args.team)
    if team is None:
        raise SetupFailed(f"no Linear team with key {args.team!r}")

    resolved = {}
    guard_failures = []
    for project_id in args.project:
        linear_project_id, message = guard_project(client, configuration_directory, project_id, team)
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
        "--client-id", help="the registered Linear OAuth application's client id "
        "(else $YH_LINEAR_CLIENT_ID, else config.toml [linear] client_id)",
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
            return check_command(args, configuration_directory, transport, keychain_secret)
        return reset_command(args, configuration_directory, transport, keychain_secret)
    except SetupFailed as error:
        print(f"scratch-linear: cannot run: {error}", file=sys.stderr)
        return 2
    except LinearError as error:
        print(f"scratch-linear: failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
