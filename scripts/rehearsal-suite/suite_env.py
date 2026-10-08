"""
Environment plumbing for the rehearsal scenario suite (P15.3): Suite Projects, fixture trees,
Orca ADE, the `yh` runner, Journal snapshots, and the Linear clients (app + Operator).

Nothing in this module prints a secret or a token. `scratch_linear.keychain_secret` already
guards that for the Keychain read; this module never logs a header or a GraphQL variable that
could carry one.
"""

import importlib.util
import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
import tomllib
from dataclasses import dataclass, field
from datetime import date, timedelta
from pathlib import Path

SUITE_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = SUITE_DIR.parent

_sleep = time.sleep  # a private, independently-patchable reference; see YhRunner.run's retry

DEFAULT_CONFIGURATION_DIRECTORY = Path.home() / ".config" / "yellowhammer"
DEFAULT_ROOT = Path.home() / "Library" / "Caches" / "dev.yellowhammer" / "rehearsal-suite"

SUITE_PROJECTS = {
    "rehearsal-suite-a": "Rehearsal Suite A",
    "rehearsal-suite-b": "Rehearsal Suite B",
}

DEFAULT_LIMITS = {
    "review_rounds_max": 2,
    "attempts_per_work_card": 3,
    "overdue_nights_max": 3,
    "reselections_max": 2,
    "consecutive_refusals_max": 3,
    "failed_adoptions_max": 2,
}

DEFAULT_SCHEDULE = {
    "night_start": "22:00",
    "night_end": "06:00",
    "build_every_minutes": 15,
}

DEFAULT_REPO_ROLES = {
    "fixture-backend": "backend",
    "fixture-web": "web",
    "fixture-mobile": "mobile",
}


class SetupFailed(Exception):
    """Preflight, setup or reset could not proceed: nothing was run."""


# MARK: - Loading the sibling tools as modules


def _load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


scratch_linear = _load_module("scratch_linear", SCRIPTS_DIR / "scratch-linear" / "scratch_linear.py")
rehearsal_fixtures = _load_module(
    "rehearsal_fixtures", SCRIPTS_DIR / "rehearsal-fixtures" / "rehearsal_fixtures.py"
)


# MARK: - Branch sanitiser (replicated; see rehearsal_fixtures.feature_branch)


def feature_branch(project_id, feature_name):
    return rehearsal_fixtures.feature_branch(project_id, feature_name)


def is_reported_feature_branch(reported, requested):
    """Whether a reported Feature Branch (from Orca ADE) matches the requested one. Orca ADE may
    prefix the branch (e.g. `team/rozd/yh-feature-1` when requested as `yh-feature-1`), so both
    an exact match and a match where reported ends with `/ + requested` are valid."""
    return bool(reported) and (reported == requested or reported.endswith("/" + requested))


# MARK: - Nights


def night(k, today=None):
    """Night k of a scenario: thirty days before today, plus (k - 1) days. A past date, so a land
    Act always closes it."""
    today = today or date.today()
    return (today - timedelta(days=30) + timedelta(days=k - 1)).isoformat()


# MARK: - Project TOML rendering


def _toml_string(value):
    escaped = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _toml_literal_string(value):
    """A TOML literal string (single-quoted, no escaping): used for `check` commands whose shell
    quoting would otherwise fight TOML's own escaping. Cannot hold a single quote or a newline."""
    if "'" in value or "\n" in value:
        raise ValueError(f"cannot render {value!r} as a TOML literal string (contains ' or a newline)")
    return f"'{value}'"


def render_project_toml(
    *,
    project_id,
    name,
    installation,
    code_hosting_connection,
    linear_project,
    spec_source,
    repos,
    limits=None,
    schedule=None,
    route="claude/sonnet/medium",
    fallbacks=("claude/opus/high",),
):
    """Renders one Project's TOML file exactly as `ProjectConfigurationDecoder` expects it: id,
    name, spec_source, [board.linear] (installation, project), [code_hosting] (connection, a name
    in the machine's Code Hosting Connection registry), [[repos]]
    (path/role/check/protected_paths), [limits], [schedule], and a single [[routing]] override."""
    lines = [
        f"id = {_toml_string(project_id)}",
        f"name = {_toml_string(name)}",
        f"spec_source = {_toml_string(spec_source)}",
        "",
        "[board.linear]",
        f"connection = {_toml_string(installation)}",
        f"project = {_toml_string(linear_project)}",
        "",
        "[code_hosting]",
        f"connection = {_toml_string(code_hosting_connection)}",
        "",
    ]
    for repo in repos:
        lines.append("[[repos]]")
        lines.append(f"name = {_toml_string(repo['name'])}")
        lines.append(f"path = {_toml_string(repo['path'])}")
        lines.append(f"role = {_toml_string(repo['role'])}")
        check = repo.get("check", "true")
        if repo.get("check_literal"):
            lines.append(f"check = {_toml_literal_string(check)}")
        else:
            lines.append(f"check = {_toml_string(check)}")
        protected = repo.get("protected_paths") or []
        if protected:
            joined = ", ".join(_toml_string(p) for p in protected)
            lines.append(f"protected_paths = [{joined}]")
        lines.append("")

    merged_limits = dict(DEFAULT_LIMITS)
    merged_limits.update(limits or {})
    lines.append("[limits]")
    for key, value in merged_limits.items():
        lines.append(f"{key} = {value}")
    lines.append("")

    merged_schedule = dict(DEFAULT_SCHEDULE)
    merged_schedule.update(schedule or {})
    lines.append("[schedule]")
    for key, value in merged_schedule.items():
        if isinstance(value, str):
            lines.append(f"{key} = {_toml_string(value)}")
        else:
            lines.append(f"{key} = {value}")
    lines.append("")

    lines.append("[[routing]]")
    lines.append(f"route = {_toml_string(route)}")
    fallback_list = ", ".join(_toml_string(item) for item in fallbacks)
    lines.append(f"fallbacks = [{fallback_list}]")
    lines.append("")

    return "\n".join(lines)


def read_linear_project(configuration_directory, project_id):
    """The `[board.linear] project` the earlier `yh setup --init` wrote, preserved across scenario rewrites."""
    return scratch_linear.load_linear_project_id(configuration_directory, project_id)


def read_project_installation(configuration_directory, project_id):
    """The `[board.linear] installation` the earlier `yh setup --init` wrote, preserved likewise."""
    return scratch_linear.load_project_installation(configuration_directory, project_id)


def read_project_code_hosting_connection(configuration_directory, project_id):
    """The `[code_hosting] connection` the earlier `yh setup --init` wrote, preserved likewise.
    Raises `scratch_linear.ProjectError` when the Project file or the key is missing, as
    `read_project_installation` does."""
    path = project_file_path(configuration_directory, project_id)
    if not path.is_file():
        raise scratch_linear.ProjectError(f"no Project file at {path}")
    with path.open("rb") as handle:
        data = tomllib.load(handle)
    connection = data.get("code_hosting", {}).get("connection")
    if not connection:
        raise scratch_linear.ProjectError(f"Project {project_id!r} has no [code_hosting] connection")
    return connection


def write_project_file(configuration_directory, project_id, text):
    path = configuration_directory / "projects" / f"{project_id}.toml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def project_file_path(configuration_directory, project_id):
    return configuration_directory / "projects" / f"{project_id}.toml"


def read_operator_identity(configuration_directory, installation_name):
    """`operator` of `[board.linear.connections.<name>]` in `config.toml`, or None when unset."""
    path = configuration_directory / "config.toml"
    if not path.is_file():
        return None
    with path.open("rb") as handle:
        data = tomllib.load(handle)
    installations = data.get("board", {}).get("linear", {}).get("connections", {})
    return (installations.get(installation_name) or {}).get("operator")


# MARK: - Stand-in commits (a rehearsal Night never dispatches an agent CLI to make one)

STAND_IN_AUTHOR_NAME = "Yellowhammer Rehearsal Suite"
STAND_IN_AUTHOR_EMAIL = "rehearsal-suite@yellowhammer.invalid"
STAND_IN_DATE = "2026-03-01T00:00:00Z"


def _stand_in_git_env(extra=None):
    env_vars = dict(os.environ)
    env_vars.update({
        "GIT_AUTHOR_NAME": STAND_IN_AUTHOR_NAME, "GIT_AUTHOR_EMAIL": STAND_IN_AUTHOR_EMAIL,
        "GIT_AUTHOR_DATE": STAND_IN_DATE,
        "GIT_COMMITTER_NAME": STAND_IN_AUTHOR_NAME, "GIT_COMMITTER_EMAIL": STAND_IN_AUTHOR_EMAIL,
        "GIT_COMMITTER_DATE": STAND_IN_DATE,
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
    })
    if extra:
        env_vars.update(extra)
    return env_vars


def _git(args, cwd, env=None, check=True):
    result = subprocess.run(
        ["git", *args], cwd=str(cwd), env=_stand_in_git_env(env), capture_output=True, text=True
    )
    if check and result.returncode != 0:
        raise SetupFailed(f"git {' '.join(args)} (in {cwd}) failed: {result.stderr.strip()}")
    return result


def stand_in_commit(worktree_path, label):
    """Writes `STAND-IN-<label>.md`, commits it with a fixed author/committer identity and date,
    and asserts the Worktree is clean afterward. Stands in for the work a real Night's worker
    would have committed — a rehearsal Night never dispatches an agent CLI to make one. Returns
    the new commit's SHA."""
    marker = Path(worktree_path) / f"STAND-IN-{label}.md"
    marker.write_text(f"Stand-in work for {label} (rehearsal suite fixture).\n")
    _git(["add", "-A"], cwd=worktree_path)
    _git(["commit", "-m", f"Stand-in work: {label} (rehearsal suite fixture)"], cwd=worktree_path)
    status = _git(["status", "--porcelain"], cwd=worktree_path)
    if status.stdout.strip():
        raise SetupFailed(f"{worktree_path}: not clean after stand_in_commit({label!r}): {status.stdout!r}")
    return _git(["rev-parse", "HEAD"], cwd=worktree_path).stdout.strip()


# MARK: - Applying a rehearsal-fixtures scenario to an already-built tree


def apply_fixture(root, project_id, scenario_name, *, repo=None, feature=None, branch=None):
    """Calls `rehearsal_fixtures.py apply <scenario_name>` against an already-built tree."""
    args = [
        sys.executable, str(SCRIPTS_DIR / "rehearsal-fixtures" / "rehearsal_fixtures.py"),
        "apply", scenario_name, "--root", str(root), "--project", project_id,
    ]
    repos = [repo] if isinstance(repo, str) else (repo or [])
    for name in repos:
        args += ["--repo", name]
    if feature is not None:
        args += ["--feature", feature]
    elif branch is not None:
        args += ["--branch", branch]
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise SetupFailed(
            f"rehearsal_fixtures.py apply {scenario_name} --project {project_id} failed: "
            f"{result.stderr or result.stdout}"
        )
    return result.stdout


# MARK: - yh argument building


def build_act_args(act, *, project, night=None, force=True, rehearsal=True, feature=None, result_fixtures=None):
    """Builds the argument list for `yh author|build|land --project ...`."""
    args = [act, "--project", project]
    if force:
        args.append("--force")
    if rehearsal:
        args.append("--rehearsal")
    if night is not None:
        args += ["--night", night]
    if feature is not None:
        args += ["--feature", feature]
    args += _result_fixture_args(result_fixtures)
    return args


def build_rehearse_args(*, project, night=None, result_fixtures=None):
    """Builds the argument list for `yh rehearse --project ...`."""
    args = ["rehearse", "--project", project]
    if night is not None:
        args += ["--night", night]
    args += _result_fixture_args(result_fixtures)
    return args


def _result_fixture_args(result_fixtures):
    args = []
    for entry in result_fixtures or []:
        if len(entry) == 2:
            pass_name, fixture = entry
            args += ["--result-fixture", f"{pass_name}={fixture}"]
        elif len(entry) == 3:
            pass_name, card_issue_id, fixture = entry
            args += ["--result-fixture", f"{pass_name}@{card_issue_id}={fixture}"]
        else:
            raise ValueError(f"a --result-fixture entry must have 2 or 3 elements, got {entry!r}")
    return args


# MARK: - yh runner


class YhRunner:
    """Runs `yh` Acts, `rehearse`, `validate` and `setup`, one log file per invocation, numbered
    within its scenario."""

    #: Matches an Act's own report of a transient board failure (Linear answering 5xx, or the
    #: request not reaching/timing out); the Act itself already recorded `ActIncomplete` and
    #: released its lease, so a retry here just stands in for the Act's next scheduled firing.
    TRANSIENT_BOARD_PATTERN = re.compile(r"Linear answered with HTTP 5|could not reach|timed out")

    def __init__(self, yh_executable, work_directory, act_timeout, retry_delay=30.0, max_retries=2):
        self.yh_executable = yh_executable
        self.work_directory = work_directory
        self.act_timeout = act_timeout
        self.retry_delay = retry_delay
        self.max_retries = max_retries
        self._counters = {}

    def next_step(self, scenario):
        n = self._counters.get(scenario, 0) + 1
        self._counters[scenario] = n
        return n

    def _scenario_directory(self, scenario):
        directory = self.work_directory / scenario
        directory.mkdir(parents=True, exist_ok=True)
        return directory

    def _log_path(self, scenario, label):
        n = self.next_step(scenario)
        return self._scenario_directory(scenario) / f"{n:02d}-{label}.log"

    def _act_environment(self, extra_env):
        """Every `yh` invocation's environment: the real environment, plus `LLVM_PROFILE_FILE` so
        a Debug build's coverage data lands under the work directory instead of the cwd."""
        env_vars = dict(os.environ)
        profraw_dir = self.work_directory / "profraw"
        profraw_dir.mkdir(parents=True, exist_ok=True)
        env_vars["LLVM_PROFILE_FILE"] = str(profraw_dir / "%p.profraw")
        if extra_env:
            env_vars.update(extra_env)
        return env_vars

    @classmethod
    def is_transient_board_failure(cls, returncode, output):
        """Whether a finished (non-timed-out) Act failure looks like a transient Linear outage,
        worth a retry rather than a suite failure."""
        if not returncode:
            return False
        return bool(cls.TRANSIENT_BOARD_PATTERN.search(output or ""))

    def _run_once(self, log_path, args, timeout, extra_env, mode):
        env_vars = self._act_environment(extra_env)
        command = [str(self.yh_executable), *args]
        with log_path.open(mode) as handle:
            handle.write("$ " + " ".join(command) + "\n")
            handle.flush()
            try:
                result = subprocess.run(
                    command, stdout=handle, stderr=subprocess.STDOUT, env=env_vars,
                    cwd=str(self.work_directory), timeout=timeout or self.act_timeout,
                )
                returncode = result.returncode
            except subprocess.TimeoutExpired:
                handle.write("\n[rehearsal-suite: timed out]\n")
                returncode = None
        return returncode, log_path.read_text()

    def run(self, scenario, label, args, timeout=None, extra_env=None, retry=True):
        """Runs `yh`, logging to `<work>/<scenario>/<nn>-<label>.log`. When `retry` (the default), a
        run that fails with a transient board pattern is run again, up to `max_retries` times,
        `retry_delay` apart, every attempt appended to the same log file: an Act that failed so
        recorded `ActIncomplete` and released its lease, and `setup` is idempotent, so a retry
        stands in for the next scheduled firing or the Operator re-running setup. `validate` passes
        `retry=False`: it never talks to Linear."""
        log_path = self._log_path(scenario, label)
        returncode, output = self._run_once(log_path, args, timeout, extra_env, mode="w")
        attempts = 0
        while retry and attempts < self.max_retries and self.is_transient_board_failure(returncode, output):
            attempts += 1
            # A module-level name (not `time.sleep` itself) so tests can patch just this call
            # without perturbing subprocess's own internal use of the shared `time` module.
            _sleep(self.retry_delay)
            with log_path.open("a") as handle:
                handle.write(
                    f"\n[rehearsal-suite: transient board failure, retry {attempts} of "
                    f"{self.max_retries} after {self.retry_delay:.0f}s]\n"
                )
            returncode, output = self._run_once(log_path, args, timeout, extra_env, mode="a")
        return returncode, output, log_path

    def start(self, scenario, label, args, extra_env=None):
        """Starts an Act and returns (process, log_path, file_handle); the caller owns the handle
        and must close it once the process ends. Never retried."""
        log_path = self._log_path(scenario, label)
        env_vars = self._act_environment(extra_env)
        command = [str(self.yh_executable), *args]
        handle = log_path.open("w")
        handle.write("$ " + " ".join(command) + "\n")
        handle.flush()
        process = subprocess.Popen(
            command, stdout=handle, stderr=subprocess.STDOUT, env=env_vars, cwd=str(self.work_directory)
        )
        return process, log_path, handle

    def run_act(
        self, scenario, act, project, *, night=None, feature=None, result_fixtures=None,
        timeout=None, extra_env=None, label=None, retry=True,
    ):
        args = build_act_args(act, project=project, night=night, feature=feature, result_fixtures=result_fixtures)
        return self.run(scenario, label or act, args, timeout=timeout, extra_env=extra_env, retry=retry)

    def start_act(
        self, scenario, act, project, *, night=None, feature=None, result_fixtures=None,
        extra_env=None, label=None,
    ):
        args = build_act_args(act, project=project, night=night, feature=feature, result_fixtures=result_fixtures)
        return self.start(scenario, label or act, args, extra_env=extra_env)

    def run_rehearse(
        self, scenario, project, *, night=None, result_fixtures=None, timeout=None, label="rehearse", retry=True,
    ):
        args = build_rehearse_args(project=project, night=night, result_fixtures=result_fixtures)
        return self.run(scenario, label, args, timeout=timeout, retry=retry)

    def start_rehearse(self, scenario, project, *, night=None, result_fixtures=None, label="rehearse", extra_env=None):
        args = build_rehearse_args(project=project, night=night, result_fixtures=result_fixtures)
        return self.start(scenario, label, args, extra_env=extra_env)

    def run_validate(self, scenario, label="validate"):
        return self.run(scenario, label, ["validate"], retry=False)

    def run_setup(self, scenario, args, label="setup"):
        return self.run(scenario, label, ["setup", *args])

    def run_project_remove(self, project_id, label=None):
        """`yh project remove <id> --yes`: unloads/deletes the Project's LaunchAgents (if any were
        installed), its Act logs, and `projects/<id>.toml`. Logged under the `_teardown` scenario."""
        return self.run(
            "_teardown", label or f"project-remove-{project_id}",
            ["project", "remove", project_id, "--yes"], retry=False,
        )


# MARK: - Journal snapshot


class JournalSnapshot:
    """A read-write copy of a Journal (WAL-safe) opened for read-only use by the suite."""

    def __init__(self, path):
        self.path = path
        self._connection = sqlite3.connect(str(path))
        self._connection.row_factory = sqlite3.Row

    def close(self):
        self._connection.close()

    def rows(self, sql, args=()):
        cursor = self._connection.execute(sql, args)
        return [dict(row) for row in cursor.fetchall()]

    def events(self, type=None):
        if type:
            rows = self.rows("SELECT * FROM event WHERE type = ? ORDER BY id", (type,))
        else:
            rows = self.rows("SELECT * FROM event ORDER BY id")
        for row in rows:
            raw = row.get("payload")
            row["payload"] = json.loads(raw) if raw else {}
        return rows

    def cards(self):
        return self.rows("SELECT * FROM card ORDER BY id")

    def features(self):
        return self.rows("SELECT * FROM feature ORDER BY id")

    def feature_repositories(self):
        return self.rows("SELECT * FROM feature_repository ORDER BY feature_id, repository")

    def nights(self):
        return self.rows("SELECT * FROM night ORDER BY id")

    def worktrees(self):
        return self.rows("SELECT * FROM worktree ORDER BY id")

    def night_id(self, night_start):
        rows = self.rows("SELECT id FROM night WHERE night_start = ?", (night_start,))
        return rows[0]["id"] if rows else None


def snapshot_journal(configuration_directory, work_directory, scenario, project_id, label, step_number):
    src = configuration_directory / "journals" / f"{project_id}.db"
    directory = work_directory / scenario
    directory.mkdir(parents=True, exist_ok=True)
    dest = directory / f"{step_number:02d}-{label}.db"
    shutil.copyfile(src, dest)
    wal = src.with_name(src.name + "-wal")
    if wal.exists():
        shutil.copyfile(wal, dest.with_name(dest.name + "-wal"))
    return JournalSnapshot(dest)


# MARK: - Linear: reads with the app credential


ISSUE_QUERY = """
query($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
    description
    state { name type }
    parent { id }
    project { id }
    labels { nodes { name } }
    assignee { id }
  }
}
"""

COMMENTS_QUERY = """
query($id: String!, $after: String) {
  issue(id: $id) {
    comments(first: 50, after: $after) {
      nodes { id body parent { id } user { id } }
      pageInfo { hasNextPage endCursor }
    }
  }
}
"""

PROJECT_ISSUES_QUERY = """
query($id: ID!, $after: String) {
  issues(filter: {project: {id: {eq: $id}}}, first: 50, after: $after, includeArchived: false) {
    nodes { id }
    pageInfo { hasNextPage endCursor }
  }
}
"""

#: `projectDelete` trashes a Linear project (restorable); Linear deprecated `projectArchive` in its
#: favor. This is the one write `teardown` sends to Linear, through the scratch app's own credential.
PROJECT_DELETE_MUTATION = "mutation($id: String!) { projectDelete(id: $id) { success } }"


def delete_linear_project(client, linear_project_id):
    data = client.graphql(PROJECT_DELETE_MUTATION, {"id": linear_project_id})
    return bool(data.get("projectDelete", {}).get("success"))


def _is_not_found_error(error):
    """Whether a `LinearError` looks like Linear reporting the object is already gone — tolerated by
    `teardown`, never raised as a failure. Matches `scratch_linear`'s own convention
    (`"Entity not found"`); a bare "not found" elsewhere in a message is not enough."""
    return "entity not found" in str(error).lower()


class LinearReader:
    """Reads through the scratch app's own credential."""

    def __init__(self, client):
        self._client = client

    def issue(self, issue_id):
        """The issue, or None when Linear has no issue with that id (it answers `Entity not found`
        rather than a null issue)."""
        try:
            data = self._client.graphql(ISSUE_QUERY, {"id": issue_id})
        except scratch_linear.LinearError as error:
            if "Entity not found" in str(error):
                return None
            raise
        return data["issue"]

    def comments(self, issue_id):
        results = []
        after = None
        while True:
            data = self._client.graphql(COMMENTS_QUERY, {"id": issue_id, "after": after})
            connection = data["issue"]["comments"]
            results.extend(connection["nodes"])
            page_info = connection["pageInfo"]
            if not page_info["hasNextPage"]:
                return results
            after = page_info["endCursor"]

    def project_issue_ids(self, linear_project_id):
        ids = []
        after = None
        while True:
            data = self._client.graphql(PROJECT_ISSUES_QUERY, {"id": linear_project_id, "after": after})
            connection = data["issues"]
            ids.extend(node["id"] for node in connection["nodes"])
            page_info = connection["pageInfo"]
            if not page_info["hasNextPage"]:
                return ids
            after = page_info["endCursor"]


# MARK: - Linear: the Operator's own gestures


class OperatorClient:
    """The Operator's board gestures, authenticated with a personal API key: `Authorization:
    <key>`, never `Bearer`. Never logs the key."""

    def __init__(self, transport, api_key, graphql_url=None):
        self._transport = transport
        self._api_key = api_key
        self._graphql_url = graphql_url or scratch_linear.GRAPHQL_URL

    def graphql(self, query, variables=None):
        status, text = self._transport.post_json(
            self._graphql_url, {"query": query, "variables": variables or {}},
            headers={"Authorization": self._api_key},
        )
        try:
            payload = json.loads(text)
        except json.JSONDecodeError as error:
            raise scratch_linear.LinearError(
                f"could not parse the Linear GraphQL response (HTTP {status})"
            ) from error
        if payload.get("errors"):
            raise scratch_linear.LinearError(f"Linear GraphQL error: {payload['errors']}")
        if status != 200:
            raise scratch_linear.LinearError(f"Linear GraphQL request failed (HTTP {status})")
        return payload.get("data") or {}

    def viewer_id(self):
        data = self.graphql("query { viewer { id } }")
        return data["viewer"]["id"]

    def reply(self, issue_id, parent_comment_id, body):
        mutation = (
            "mutation($issueId: String!, $parentId: String!, $body: String!) { "
            "commentCreate(input: {issueId: $issueId, parentId: $parentId, body: $body}) { success } }"
        )
        data = self.graphql(mutation, {"issueId": issue_id, "parentId": parent_comment_id, "body": body})
        return bool(data.get("commentCreate", {}).get("success"))

    def _team_states(self, issue_id):
        issue_data = self.graphql(
            "query($id: String!) { issue(id: $id) { team { id states { nodes { id name type } } } } }",
            {"id": issue_id},
        )
        return issue_data["issue"]["team"]["states"]["nodes"]

    def _move_to_matched_state(self, issue_id, match, description):
        if match is None:
            raise scratch_linear.LinearError(f"no workflow state {description} in the issue's team")
        data = self.graphql(
            "mutation($id: String!, $stateId: String!) { "
            "issueUpdate(id: $id, input: {stateId: $stateId}) { success } }",
            {"id": issue_id, "stateId": match["id"]},
        )
        return bool(data.get("issueUpdate", {}).get("success"))

    def move_to_state(self, issue_id, state_name):
        """Moves an issue to the team's workflow state of this exact name."""
        states = self._team_states(issue_id)
        match = next((entry for entry in states if entry["name"] == state_name), None)
        return self._move_to_matched_state(issue_id, match, f"named {state_name!r}")

    def move_to_state_of_type(self, issue_id, state_type):
        """Moves an issue to the team's workflow state of this Linear state *type* (e.g.
        `"canceled"`, which Linear names `Canceled`, not the glossary's `Shelved`)."""
        states = self._team_states(issue_id)
        match = next((entry for entry in states if entry["type"] == state_type), None)
        return self._move_to_matched_state(issue_id, match, f"of type {state_type!r}")

    SCOPE_LINE_PREFIX = "**Scope:** "
    MANAGED_START = "<!-- yh:managed:start -->"
    MANAGED_END = "<!-- yh:managed:end -->"

    def declare_scope(self, issue_id, new_line):
        """The Operator declares a Card's scope: its `**Scope:** ` line inside the Managed Block, which
        the build Act's Readiness Check reads back. Replaces the line the Engine rendered, or adds one
        right after the start marker when the block has none yet — a freshly authored Card's block
        carries only its Architectural Brief and Definition of Done."""
        if not new_line.startswith(self.SCOPE_LINE_PREFIX):
            new_line = self.SCOPE_LINE_PREFIX + new_line
        data = self.graphql("query($id: String!) { issue(id: $id) { description } }", {"id": issue_id})
        description = data["issue"]["description"] or ""
        start = description.find(self.MANAGED_START)
        end = description.find(self.MANAGED_END)
        if start == -1 or end == -1 or end < start:
            raise scratch_linear.LinearError(f"issue {issue_id}: no yh:managed block found")
        lines = description[start:end].split("\n")
        scope_indices = [i for i, line in enumerate(lines) if line.strip().startswith(self.SCOPE_LINE_PREFIX)]
        if scope_indices:
            lines[scope_indices[0]] = new_line
        else:
            lines.insert(1, new_line)
        new_description = description[:start] + "\n".join(lines) + description[end:]
        self.graphql(
            "mutation($id: String!, $description: String!) { "
            "issueUpdate(id: $id, input: {description: $description}) { success } }",
            {"id": issue_id, "description": new_description},
        )


# MARK: - Orca ADE


def orca_json(args, timeout=60):
    try:
        result = subprocess.run(["orca", *args, "--json"], capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError as error:
        raise SetupFailed("orca is not installed or not on PATH") from error
    except subprocess.TimeoutExpired as error:
        raise SetupFailed(f"orca {' '.join(args)} timed out") from error
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise SetupFailed(f"orca {' '.join(args)}: could not parse JSON output: {result.stdout!r}") from error
    return result.returncode, payload


def orca_status_ready():
    """`{"ok": true, "result": {"app": {...}, "runtime": {"state": "ready", "reachable": true, ...}}}`."""
    returncode, payload = orca_json(["status"])
    if returncode != 0 or not payload.get("ok"):
        return False
    runtime = (payload.get("result") or {}).get("runtime") or {}
    return runtime.get("state") == "ready" and bool(runtime.get("reachable"))


def orca_worktree_list(repo_path):
    """Orca's Worktrees of the repository at `repo_path`; none when Orca does not know the repository
    yet (`repo_not_found`: a Project's first reset, before its fixture clones were registered)."""
    returncode, payload = orca_json(["worktree", "list", "--repo", f"path:{repo_path}"])
    if (payload.get("error") or {}).get("code") == "repo_not_found":
        return []
    if not payload.get("ok"):
        raise SetupFailed(f"orca worktree list --repo path:{repo_path} failed: {payload.get('error')}")
    result = payload.get("result") or {}
    return result.get("worktrees") or []


def orca_worktree_rm(worktree_id, tolerate_not_found=True):
    returncode, payload = orca_json(["worktree", "rm", "--worktree", f"id:{worktree_id}", "--force"])
    if payload.get("ok"):
        return True
    error = payload.get("error") or {}
    message = (error.get("message") or "").lower()
    if tolerate_not_found and "not found" in message:
        return False
    raise SetupFailed(f"orca worktree rm --worktree id:{worktree_id} failed: {error}")


def is_primary_checkout(worktree, clone_path):
    """Whether an `orca worktree list` entry is the clone's own primary checkout (branch main, its
    path the clone path itself) — `orca worktree rm --force` refuses to delete it
    ("Refusing to delete protected worktree path"), so reset must never try."""
    try:
        return Path(worktree["path"]).resolve() == Path(clone_path).resolve()
    except (KeyError, OSError):
        return False


def orca_repo_add(path, tolerate_registered=True):
    returncode, payload = orca_json(["repo", "add", "--path", str(path)])
    if payload.get("ok"):
        return True
    error = payload.get("error") or {}
    message = (error.get("message") or "").lower()
    if tolerate_registered and ("already" in message or "registered" in message):
        return False
    raise SetupFailed(f"orca repo add --path {path} failed: {error}")


# MARK: - Fixture trees


def fixture_manifest_path(root, project_id):
    return root / project_id / "manifest.json"


def load_fixture_manifest(root, project_id):
    path = fixture_manifest_path(root, project_id)
    with path.open() as handle:
        return json.load(handle)


def build_fixture_tree(root, project_id, force=False):
    args = [
        sys.executable, str(SCRIPTS_DIR / "rehearsal-fixtures" / "rehearsal_fixtures.py"),
        "build", "--root", str(root), "--project", project_id,
    ]
    if force:
        args.append("--force")
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise SetupFailed(f"rehearsal_fixtures build --project {project_id} failed: {result.stderr or result.stdout}")
    return load_fixture_manifest(root, project_id)


def default_repo_declarations(manifest):
    """`[[repos]]` entries (name/path/role/protected_paths) from a fixture manifest, in the order
    fixed by `rehearsal_fixtures`: backend, web, mobile."""
    repos = []
    for repo in manifest["repos"]:
        repos.append({
            "name": repo["name"],
            "path": repo["path"],
            "role": repo["role"],
            "protected_paths": repo.get("protected_paths") or [],
        })
    return repos


# MARK: - Environment


@dataclass
class Environment:
    app: Path
    team: str
    root: Path
    work_directory: Path
    configuration_directory: Path
    act_timeout: float
    transport: object = None
    yh: YhRunner = None
    #: The Board Connection's local name: from `--board-connection`, else resolved to the sole entry
    #: by `resolve_installation` (which stores the resolved name back here).
    installation: str | None = None
    #: The Code Hosting Connection's registry name: from `--code-hosting-connection`, else resolved
    #: to the sole entry by `resolve_code_hosting_connection` (which stores the resolved name back here).
    code_hosting_connection: str | None = None
    app_client: object = None
    team_id: str = None
    linear: LinearReader = None
    operator_client: OperatorClient = None
    step_counters: dict = field(default_factory=dict)

    @property
    def yh_executable(self):
        return self.app / "Contents" / "MacOS" / "yh"

    def next_step(self, scenario):
        n = self.step_counters.get(scenario, 0) + 1
        self.step_counters[scenario] = n
        return n

    def snapshot(self, scenario, project_id, label):
        step = self.next_step(scenario)
        return snapshot_journal(self.configuration_directory, self.work_directory, scenario, project_id, label, step)


def make_environment(
    app, team, root, work_directory, configuration_directory, act_timeout, transport=None, installation=None,
    code_hosting_connection=None,
):
    transport = transport or scratch_linear.HTTPTransport()
    env = Environment(
        app=app, team=team, root=root, work_directory=work_directory,
        configuration_directory=configuration_directory, act_timeout=act_timeout, transport=transport,
        installation=installation, code_hosting_connection=code_hosting_connection,
    )
    env.yh = YhRunner(env.yh_executable, work_directory, act_timeout)
    return env


# MARK: - Ensure Projects exist / reset


def resolve_installation(env):
    """The Board Connection this run uses (`env.installation`, else the sole one in `config.toml`),
    resolved once: the resolved local name is stored back on `env.installation`."""
    try:
        machine = scratch_linear.load_machine_config(env.configuration_directory, env.installation)
    except scratch_linear.SetupFailed as error:
        raise SetupFailed(str(error)) from error
    env.installation = machine.name
    return machine


def _code_hosting_registry(configuration_directory):
    """The names in `[code_hosting.github.connections]` of `config.toml`; empty when the file or the
    registry is absent. Read-only."""
    path = configuration_directory / "config.toml"
    if not path.is_file():
        return {}
    with path.open("rb") as handle:
        data = tomllib.load(handle)
    return data.get("code_hosting", {}).get("github", {}).get("connections", {})


def resolve_code_hosting_connection(env):
    """The Code Hosting Connection this run's Projects select (`env.code_hosting_connection`, else the
    sole entry in `config.toml`'s registry), resolved once: the resolved name is stored back on
    `env.code_hosting_connection`."""
    entries = _code_hosting_registry(env.configuration_directory)
    if env.code_hosting_connection is not None:
        name = env.code_hosting_connection
        if name not in entries:
            registered = ", ".join(sorted(entries)) or "none"
            raise SetupFailed(
                f"no Code Hosting Connection named {name!r} in config.toml (registered: {registered})"
            )
    elif not entries:
        raise SetupFailed("no Code Hosting Connection in config.toml; run yh config connect-code-hosting github --token-stdin")
    elif len(entries) > 1:
        raise SetupFailed(
            f"config.toml has several Code Hosting Connections ({', '.join(sorted(entries))}); "
            "pass --code-hosting-connection <name>"
        )
    else:
        name = next(iter(entries))
    env.code_hosting_connection = name
    return name


def ensure_project(env, project_id):
    """Builds the fixture tree and runs `yh setup --init` the first time a suite Project is used;
    later runs reuse the Project file already on disk."""
    project_file = project_file_path(env.configuration_directory, project_id)
    if project_file.is_file():
        return
    name = SUITE_PROJECTS[project_id]
    installation = resolve_installation(env).name
    code_hosting_connection = resolve_code_hosting_connection(env)
    manifest = build_fixture_tree(env.root, project_id, force=False)
    args = [
        "--init", "--project", project_id, "--project-name", name, "--board-connection", installation,
        "--code-hosting-connection", code_hosting_connection,
        "--linear-team", env.team,
        "--spec-source", manifest["spec_source"],
        # A rehearsal Night never pushes, and the fixture repositories' origin is a local bare repository
        # with no GitHub token behind it, so setup's GitHub check would refuse these Projects. The Project
        # still selects a registry connection, whose token is never used for the same reason.
        "--skip-github-check",
    ]
    for repo in default_repo_declarations(manifest):
        args += ["--repo", f"{repo['name']},{repo['role']},{repo['path']},true"]
    returncode, output, log_path = env.yh.run_setup("_setup", args, label=f"setup-{project_id}")
    if returncode != 0:
        raise SetupFailed(f"yh setup --init --project {project_id} failed; see {log_path}\n{output}")


def _removable_worktrees(env, project_id):
    """Non-primary Orca Worktrees of this Project's fixture repositories — empty when the fixture
    tree, or a repository's clone, doesn't exist yet. Read-only: does not remove anything."""
    manifest_path = fixture_manifest_path(env.root, project_id)
    if not manifest_path.is_file():
        return []
    manifest = load_fixture_manifest(env.root, project_id)
    removable = []
    for repo in manifest["repos"]:
        clone_path = repo["path"]
        if not Path(clone_path).exists():
            continue
        for worktree in orca_worktree_list(clone_path):
            if is_primary_checkout(worktree, clone_path):
                continue
            removable.append(worktree)
    return removable


def _reset_worktrees_and_scratch_linear(env, project_id):
    """The suite's existing reset minus the rebuild: removes this Project's non-primary Orca
    Worktrees, then runs `scratch_linear.py reset` (archives its scratch issues, deletes its
    Journal). Shared by `reset_project` (which then rebuilds the fixture tree and re-registers it)
    and `teardown` (which does not rebuild)."""
    for worktree in _removable_worktrees(env, project_id):
        orca_worktree_rm(worktree["id"])

    reset_args = [
        sys.executable, str(SCRIPTS_DIR / "scratch-linear" / "scratch_linear.py"),
        "--configuration-directory", str(env.configuration_directory),
        "--board-connection", resolve_installation(env).name,
        "reset", "--team", env.team, "--project", project_id,
    ]
    result = subprocess.run(reset_args, capture_output=True, text=True)
    if result.returncode != 0:
        raise SetupFailed(
            f"scratch_linear.py reset --project {project_id} failed: {result.stderr or result.stdout}"
        )


def reset_project(env, project_id):
    """The suite's reset, per the README: remove this Project's Orca Worktrees, archive its scratch
    issues and delete its Journal, then rebuild its fixture tree and re-register it with Orca ADE.
    Returns the rebuilt manifest."""
    _reset_worktrees_and_scratch_linear(env, project_id)

    manifest = build_fixture_tree(env.root, project_id, force=True)
    for repo in manifest["repos"]:
        orca_repo_add(repo["path"])
    return manifest


def write_scenario_project_file(
    env, project_id, manifest, *, limits=None, schedule=None, repo_overrides=None,
    route="claude/sonnet/medium", fallbacks=("claude/opus/high",),
):
    """Rewrites the Project file with this scenario's [limits]/checks/Protected Paths and the
    Routing Table override, keeping the `[board.linear]` `connection` and `project`, and the `[code_hosting]`
    `connection`, the first `yh setup --init` wrote."""
    linear_project = read_linear_project(env.configuration_directory, project_id)
    installation = read_project_installation(env.configuration_directory, project_id)
    code_hosting_connection = read_project_code_hosting_connection(env.configuration_directory, project_id)
    repos = default_repo_declarations(manifest)
    if repo_overrides:
        by_name = {repo["name"]: repo for repo in repos}
        for name, override in repo_overrides.items():
            by_name[name].update(override)
    text = render_project_toml(
        project_id=project_id,
        name=SUITE_PROJECTS.get(project_id, project_id),
        installation=installation,
        code_hosting_connection=code_hosting_connection,
        linear_project=linear_project,
        spec_source=manifest["spec_source"],
        repos=repos,
        limits=limits,
        schedule=schedule,
        route=route,
        fallbacks=fallbacks,
    )
    return write_project_file(env.configuration_directory, project_id, text)


# MARK: - Preflight


#: How long preflight waits for an Act lease a dead run left behind: one ten-minute TTL, plus margin.
DEAD_RUN_LEASE_WAIT_SECONDS = 660.0
DEAD_RUN_LEASE_POLL_SECONDS = 15.0


def _running_yh_processes():
    result = subprocess.run(["ps", "-axww", "-o", "pid=,args="], capture_output=True, text=True)
    return result.stdout.splitlines()


def resolve_app_client(env):
    """Builds the scratch app's Linear client and resolves the scratch team, setting
    `env.app_client`, `env.team_id` and `env.linear`. Shared by `preflight` and `teardown_preflight`."""
    machine = resolve_installation(env)
    try:
        token = scratch_linear.resolve_access_token(
            env.configuration_directory, machine, lambda: env.yh_executable,
            keychain_reader=scratch_linear.keychain_token_pair,
        )
    except scratch_linear.SetupFailed as error:
        raise SetupFailed(str(error)) from error
    app_client = scratch_linear.LinearClient(env.transport, token)
    try:
        team = scratch_linear.find_team(app_client, env.team)
    except scratch_linear.LinearError as error:
        raise SetupFailed(f"could not resolve the scratch team {env.team!r}: {error}") from error
    if team is None:
        raise SetupFailed(f"no Linear team with key {env.team!r}")
    env.app_client = app_client
    env.team_id = team["id"]
    env.linear = LinearReader(app_client)


def preflight(env, selected_scenario_numbers):
    """Every guard the README's Prerequisites lists, in order; the first failure raises
    `SetupFailed` before anything is changed."""
    yh_path = env.yh_executable
    if not yh_path.is_file():
        raise SetupFailed(f"no yh executable at {yh_path}: build Yellowhammer.app first")

    if not orca_status_ready():
        raise SetupFailed("orca status does not report the runtime ready")

    git_result = subprocess.run(["git", "--version"], capture_output=True, text=True)
    if git_result.returncode != 0:
        raise SetupFailed("git is not installed or not on PATH")
    match = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", git_result.stdout)
    if not match or (int(match.group(1)), int(match.group(2))) < (2, 38):
        raise SetupFailed(f"git 2.38 or later is required; found: {git_result.stdout.strip()}")

    resolve_app_client(env)

    if selected_scenario_numbers & {5, 9, 11}:
        try:
            operator_key = scratch_linear.keychain_secret("linear-rehearsal-operator")
        except scratch_linear.SetupFailed as error:
            raise SetupFailed(str(error)) from error
        operator_client = OperatorClient(env.transport, operator_key)
        try:
            app_viewer_id = env.app_client.graphql("query { viewer { id } }")["viewer"]["id"]
            operator_viewer_id = operator_client.viewer_id()
        except scratch_linear.LinearError as error:
            raise SetupFailed(f"could not resolve the Operator credential's viewer: {error}") from error
        if operator_viewer_id == app_viewer_id:
            raise SetupFailed(
                "the Operator credential's viewer is the scratch app itself; "
                "it must be a human member of the scratch workspace"
            )
        env.operator_client = operator_client

    for line in _running_yh_processes():
        for project_id in SUITE_PROJECTS:
            if f"--project {project_id}" in line and "/yh " in line + " ":
                raise SetupFailed(f"a yh process is already running for {project_id}: {line.strip()}")

    # No `yh` runs for a suite Project, so a held Act lease belongs to a run that died — a killed Act
    # an earlier, aborted suite run left behind. It expires within one TTL; wait it out rather than
    # refuse, and give up only if it outlives that.
    for project_id in SUITE_PROJECTS:
        waited = 0.0
        while scratch_linear.journal_lease_active(env.configuration_directory, project_id):
            if waited >= DEAD_RUN_LEASE_WAIT_SECONDS:
                raise SetupFailed(
                    f"Project {project_id!r}: the Journal's Act lease is still held after "
                    f"{DEAD_RUN_LEASE_WAIT_SECONDS:.0f}s with no yh running for it"
                )
            if waited == 0:
                print(
                    f"rehearsal-suite: {project_id}: waiting for a dead run's Act lease to expire",
                    flush=True,
                )
            _sleep(DEAD_RUN_LEASE_POLL_SECONDS)
            waited += DEAD_RUN_LEASE_POLL_SECONDS


# MARK: - Teardown (P15.3 follow-up, GitHub issue #162 item 1)
#
# A suite run's `yh setup --init` Projects are real Projects: reused across runs, and left on disk
# indefinitely. A later routine `yh setup --install-jobs` would install LaunchAgents for them and
# schedule real (non-rehearsal) Nights against fixture repos. `teardown` removes everything a suite
# run leaves on the machine for each `SUITE_PROJECTS` id: its Orca Worktrees, its scratch Linear
# issues and Journal, its Project file and Act logs (`yh project remove`), its Orca ADE repository
# registrations, its Linear project, and its fixture tree. Every step is idempotent — it skips
# cleanly when its target is already gone — so a re-run after a partial failure finishes the job.


def teardown_preflight(env):
    """Every guard `teardown` needs before touching anything: a `yh` executable, Orca ready, no `yh`
    process running for a suite Project, and the scratch app client resolves. The first failure
    raises `SetupFailed` before anything is changed."""
    yh_path = env.yh_executable
    if not yh_path.is_file():
        raise SetupFailed(f"no yh executable at {yh_path}: build Yellowhammer.app first")

    if not orca_status_ready():
        raise SetupFailed("orca status does not report the runtime ready")

    for line in _running_yh_processes():
        for project_id in SUITE_PROJECTS:
            if f"--project {project_id}" in line and "/yh " in line + " ":
                raise SetupFailed(f"a yh process is already running for {project_id}: {line.strip()}")

    resolve_app_client(env)


def _is_within(path, root):
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _orca_setups_under(project_root):
    """`orca project setups`, filtered to the setups whose resolved `path` is inside
    `project_root` — matched by path containment, never by `displayName`. Read-only."""
    returncode, payload = orca_json(["project", "setups"])
    if not payload.get("ok"):
        raise SetupFailed(f"orca project setups failed: {payload.get('error')}")
    result = payload.get("result") or {}
    setups = result.get("setups") or []
    matched = []
    for setup in setups:
        path = setup.get("path")
        if not path:
            continue
        if _is_within(Path(path).resolve(), project_root):
            matched.append(setup)
    return matched


def _orca_setup_delete(setup_id):
    returncode, payload = orca_json(["project", "setup-delete", "--setup", str(setup_id)])
    if not payload.get("ok"):
        raise SetupFailed(f"orca project setup-delete --setup {setup_id} failed: {payload.get('error')}")


def _rmtree_within_root(path, root):
    """`shutil.rmtree`, refusing to remove anything outside `root` — a defense against a runaway
    teardown, never expected to trigger for a suite Project id."""
    resolved_root = root.resolve()
    resolved_path = path.resolve()
    if resolved_path != resolved_root and not _is_within(resolved_path, resolved_root):
        raise SetupFailed(f"refusing to remove {resolved_path}: not inside root {resolved_root}")
    shutil.rmtree(resolved_path)


def teardown_project(env, project_id, *, dry_run=False):
    """Tears down everything a suite run leaves behind for one Project, in order: (1) its non-primary
    Orca Worktrees and its scratch Linear issues/Journal, (2) its Project file and Act logs (`yh
    project remove`), (3) its Orca ADE repository registrations, (4) its Linear project (trashed,
    restorable), (5) its fixture tree. Every step is idempotent. Never raises for a per-step failure;
    returns `(ok, messages)`.

    Steps 1 and 2 are re-run-safety gates: `projects/<id>.toml` is the only record of this Project's
    `[board.linear] project`, and step 2 deletes it. So a step-1 failure or a step-2 failure stops this
    Project's teardown right there (steps 3-5 do not run) and keeps the Project file — a re-run can
    then read `[board.linear] project` again and finish the job. Once step 2 has succeeded the file is gone,
    so a step-4 failure from there on names the Linear project id for the Operator to trash by hand."""
    messages = []
    ok = True

    def fail(message):
        nonlocal ok
        ok = False
        messages.append(f"FAILED: {message}")

    def info(message):
        messages.append(message)

    project_file = project_file_path(env.configuration_directory, project_id)
    has_project_file = project_file.is_file()
    linear_project_id = None
    if has_project_file:
        try:
            linear_project_id = scratch_linear.load_linear_project_id(env.configuration_directory, project_id)
        except scratch_linear.ProjectError as error:
            info(f"{project_id}: could not read [board.linear] project from the Project file: {error}")

    # Step 1: non-primary Orca Worktrees, then scratch Linear reset (archives issues, deletes the Journal).
    if has_project_file:
        if dry_run:
            removable = [worktree["id"] for worktree in _removable_worktrees(env, project_id)]
            if removable:
                info(f"{project_id}: would remove Orca Worktree(s) {removable}")
            else:
                info(f"{project_id}: no non-primary Orca Worktrees to remove")
            info(
                f"{project_id}: would run scratch_linear.py reset --team {env.team} --project {project_id} "
                "(archives scratch issues, deletes the Journal)"
            )
        else:
            try:
                _reset_worktrees_and_scratch_linear(env, project_id)
                info(f"{project_id}: removed Orca Worktrees; archived scratch issues and deleted the Journal")
            except SetupFailed as error:
                fail(
                    f"{project_id}: scratch Linear reset: {error}; the Project file was kept so a re-run "
                    "can finish this Project's teardown"
                )
                return ok, messages
    else:
        info(f"{project_id}: no Project file; skipping Orca Worktree removal and the scratch Linear reset")

    # Step 2: `yh project remove` (LaunchAgents, Act logs, projects/<id>.toml).
    if has_project_file:
        if dry_run:
            info(f"{project_id}: would run `yh project remove {project_id} --yes`")
        else:
            returncode, output, log_path = env.yh.run_project_remove(project_id)
            if returncode != 0:
                fail(
                    f"{project_id}: yh project remove failed; see {log_path}\n{output}\n"
                    "the Project file was kept so a re-run can finish this Project's teardown"
                )
                return ok, messages
            info(f"{project_id}: yh project remove succeeded")
    else:
        info(f"{project_id}: no Project file; skipping yh project remove")

    # Step 3: unregister this Project's fixture repositories from Orca ADE.
    project_root = (env.root / project_id).resolve()
    try:
        setups = _orca_setups_under(project_root)
    except SetupFailed as error:
        fail(f"{project_id}: could not list Orca setups: {error}")
        setups = []
    for setup in setups:
        setup_id = setup.get("id")
        path = setup.get("path")
        if dry_run:
            info(f"{project_id}: would unregister Orca setup {setup_id} ({path})")
            continue
        try:
            _orca_setup_delete(setup_id)
            info(f"{project_id}: unregistered Orca setup {setup_id} ({path})")
        except SetupFailed as error:
            fail(f"{project_id}: {error}")

    # Step 4: trash the Linear project (restorable; tolerates it already being gone). By the time this
    # step can run, either there was never a `[board.linear] project` to delete, or steps 1-2 already succeeded
    # and the Project file is gone — so a failure here names the id for the Operator to trash by hand.
    if linear_project_id:
        if dry_run:
            info(f"{project_id}: would trash Linear project {linear_project_id} (projectDelete)")
        else:
            try:
                success = delete_linear_project(env.app_client, linear_project_id)
            except scratch_linear.LinearError as error:
                if _is_not_found_error(error):
                    info(f"{project_id}: Linear project {linear_project_id} already gone")
                else:
                    fail(
                        f"{project_id}: projectDelete {linear_project_id} failed: {error}; "
                        f"the Project file is already gone — trash Linear project {linear_project_id} "
                        "by hand"
                    )
            else:
                if success:
                    info(f"{project_id}: trashed Linear project {linear_project_id}")
                else:
                    fail(
                        f"{project_id}: projectDelete {linear_project_id} returned success=false; "
                        f"the Project file is already gone — trash Linear project {linear_project_id} "
                        "by hand"
                    )
    else:
        info(f"{project_id}: no [board.linear] project to delete")

    # Step 5: the fixture tree.
    if project_root.is_dir():
        if dry_run:
            info(f"{project_id}: would remove the fixture tree {project_root}")
        else:
            try:
                _rmtree_within_root(project_root, env.root)
                info(f"{project_id}: removed the fixture tree {project_root}")
            except SetupFailed as error:
                fail(f"{project_id}: {error}")
    else:
        info(f"{project_id}: no fixture tree at {project_root}")

    return ok, messages


def teardown(env, *, dry_run=False):
    """Tears down every suite Project, after `teardown_preflight`. Continues past a per-Project
    failure so every Project gets a teardown attempt; removes `env.root` at the end if it is then
    empty. Returns `(overall_ok, per_project_results)`, where `per_project_results` is a list of
    `(project_id, ok, messages)`. Raises `SetupFailed` only from `teardown_preflight`, before
    anything is changed."""
    teardown_preflight(env)
    overall_ok = True
    per_project_results = []
    for project_id in SUITE_PROJECTS:
        ok, messages = teardown_project(env, project_id, dry_run=dry_run)
        overall_ok = overall_ok and ok
        per_project_results.append((project_id, ok, messages))
    if not dry_run and env.root.is_dir() and not any(env.root.iterdir()):
        env.root.rmdir()
    return overall_ok, per_project_results


# MARK: - A one-shot hold Check (scenario 7): a repo's `check` that sleeps once a HOLD marker exists


def hold_check_command(hold_directory):
    """A `check` command literal that blocks once: if `<hold_directory>/HOLD` exists, it deletes
    it, writes `<hold_directory>/STARTED`, and sleeps an hour (long enough to kill mid-run); every
    other invocation is a no-op success. Rendered as a TOML literal string (`check_literal=True`)
    so the embedded double quotes need no TOML escaping."""
    return (
        f'if [ -e "{hold_directory}/HOLD" ]; then rm -f "{hold_directory}/HOLD"; '
        f': > "{hold_directory}/STARTED"; exec sleep 3600; fi; true'
    )


# MARK: - Waiting on a file, and on a set of Leases to expire


def wait_for_file(path, *, timeout=300.0, poll_interval=0.5, still_running=None, sleep=None):
    """Polls for `path` to appear. `still_running()`, when given, must stay true while waiting —
    used to fail fast if the process being waited on has already exited. Returns True once the
    file appears, False on timeout or once `still_running()` turns false."""
    sleep = sleep or _sleep
    deadline = time.monotonic() + timeout
    while not Path(path).exists():
        if still_running is not None and not still_running():
            return False
        if time.monotonic() > deadline:
            return False
        sleep(poll_interval)
    return True


def wait_until_all_expired(
    get_active_expirations, *, poll_interval=15.0, timeout=900.0, extra_delay=10.0, sleep=None,
    monotonic=None, on_tick=None,
):
    """Polls `get_active_expirations()` — a callable returning the still-unexpired ISO-8601
    timestamps of interest — until it returns an empty collection, then sleeps `extra_delay` more
    (so a caller's next read is safely past every expiry). Calls `on_tick(minute)` about once a
    minute while waiting. Raises `SetupFailed` if `timeout` elapses first."""
    sleep = sleep or _sleep
    monotonic = monotonic or time.monotonic
    start = monotonic()
    deadline = start + timeout
    last_minute = -1
    while True:
        active = get_active_expirations()
        if not active:
            break
        minute = int((monotonic() - start) // 60)
        if on_tick is not None and minute != last_minute:
            on_tick(minute)
            last_minute = minute
        if monotonic() > deadline:
            raise SetupFailed(f"timed out after {timeout:.0f}s waiting for expiry of: {sorted(active)}")
        sleep(poll_interval)
    sleep(extra_delay)


# MARK: - SIGKILL detection and leftover-process cleanup (scenarios 7 and 8)


def is_killed_by_sigkill(returncode):
    """Whether a `Popen` returncode reports the process was killed by SIGKILL: a negative signal
    number (the normal case for a directly-exec'd child) or the shell convention 128+signal."""
    return returncode in (-signal.SIGKILL, 128 + signal.SIGKILL)


def find_processes_with_command_line(command_line):
    """pids of every process whose full argument string is exactly `command_line` (e.g. the one-
    shot hold Check's `exec sleep 3600`, which replaces its own argv so `ps` shows only that)."""
    pids = []
    for line in _running_yh_processes():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit() and parts[1] == command_line:
            pids.append(int(parts[0]))
    return pids


def kill_leftover_processes(pids):
    """Best-effort SIGKILL cleanup; returns the pids it actually signalled."""
    killed = []
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            continue
        killed.append(pid)
    return killed


# MARK: - Worktree ownership by git common dir (scenario 12)


def created_issue_title(payload_text):
    """The title an Outbox `issueCreate` entry creates, read from its JSON payload
    (`{"createIssue": {"_0": {"title": …}}}` — the Engine's encoding of `BoardWrite.createIssue`), or
    None when the payload is not an issue create or carries no title."""
    try:
        payload = json.loads(payload_text)
    except (TypeError, ValueError):
        return None
    draft = (payload.get("createIssue") or {}).get("_0") if isinstance(payload, dict) else None
    title = draft.get("title") if isinstance(draft, dict) else None
    return title if isinstance(title, str) and title else None


def worktree_git_common_dir(path):
    """`git -C <path> rev-parse --path-format=absolute --git-common-dir`, or None if `path` is not
    a git checkout — Orca places Worktrees under its own workspace directory, so ownership is read
    from the checkout's git common directory, never from `path` itself."""
    result = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip()


# MARK: - The set of Linear issue ids a Journal holds (scenario 12)


def journal_issue_ids(snap):
    """Every board object id this Journal names: Feature Issues, Card Issues, Night Cards, and any
    Outbox entry's `issue_id`/`result` (an issue-creating entry's `result` is the created id)."""
    ids = set()
    for feature in snap.features():
        if feature.get("issue_id"):
            ids.add(feature["issue_id"])
    for card in snap.cards():
        if card.get("issue_id"):
            ids.add(card["issue_id"])
    for night_row in snap.nights():
        if night_row.get("night_card_issue_id"):
            ids.add(night_row["night_card_issue_id"])
    for row in snap.rows("SELECT issue_id, result FROM outbox"):
        if row.get("issue_id"):
            ids.add(row["issue_id"])
        if row.get("result"):
            ids.add(row["result"])
    return ids


def journal_run_ids(snap):
    return {row["run_id"] for row in snap.events() if row.get("run_id")}
