#!/usr/bin/env python3
"""
Unit tests for scratch_linear.py — fully offline, a fake HTTP transport records every GraphQL
request and a fake Keychain reader stands in for `security`; no test ever touches the network or
the real Keychain, and `yh` (the refresh fallback) is `/usr/bin/true` — a real, harmless binary,
never actually consulted for its output.
"""

import importlib.util
import io
import json
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path

script_path = Path(__file__).parent.parent / "scratch_linear.py"
spec = importlib.util.spec_from_file_location("scratch_linear", script_path)
scratch_linear = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scratch_linear)


TOKEN = "tok3n-value-never-printed"
TRUE_BINARY = "/usr/bin/true"


class FakeTransport:
    """Records every GraphQL request. `graphql_handler` is a callable taking (query, variables)
    and returning a (status, body-dict) pair (or raising to simulate an HTTP-level failure)."""

    def __init__(self, graphql_handler):
        self.requests = []
        self.graphql_handler = graphql_handler

    def post_json(self, url, payload, headers=None):
        self.requests.append(("json", url, payload, headers))
        query = payload["query"]
        variables = payload["variables"]
        status, body = self.graphql_handler(query, variables)
        return status, json.dumps(body)


def data_response(data):
    return 200, {"data": data}


def fresh_pair(token=TOKEN, hours_remaining=24):
    expires_at = datetime.now(timezone.utc) + timedelta(hours=hours_remaining)
    return {
        "access_token": token,
        "refresh_token": "refresh-value-never-printed",
        "expires_at": expires_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def stale_pair(token=TOKEN):
    return fresh_pair(token=token, hours_remaining=1)


class FakeKeychain:
    """A stand-in for `security find-generic-password`: `pairs` is a list consumed in order, one
    per call — so a test can script "stale, then fresh after a refresh" or "always missing"."""

    def __init__(self, pairs):
        self._pairs = list(pairs)
        self.calls = 0

    def __call__(self, account):
        self.calls += 1
        if not self._pairs:
            return None
        return self._pairs.pop(0) if len(self._pairs) > 1 else self._pairs[0]


class Args:
    def __init__(self, **kwargs):
        self.yh = kwargs.pop("yh", TRUE_BINARY)
        self.__dict__.update(kwargs)


def write_toml(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def installation_table(name, credential, workspace, operator=None):
    header = f'"{name}"' if not name.replace("-", "").replace("_", "").isalnum() else name
    text = (
        f"[board.linear.installations.{header}]\n"
        f'credential = "{credential}"\nworkspace = "{workspace}"\napp_user = "app-{name}"\n'
    )
    if operator:
        text += f'operator = "{operator}"\n'
    return text


def write_machine_config(directory, credential="keychain:linear-scratch", name="scratch"):
    write_toml(directory / "config.toml", installation_table(name, credential, f"ws-{name}"))


def write_machine_config_with(directory, tables):
    write_toml(directory / "config.toml", "\n".join(tables))


def write_project(directory, project_id, linear_project_id, installation="scratch"):
    write_toml(
        directory / "projects" / f"{project_id}.toml",
        f'id = "{project_id}"\n\n[board.linear]\ninstallation = "{installation}"\nproject = "{linear_project_id}"\n',
    )


ACT_LEASE_SCHEMA = """
CREATE TABLE act_lease (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    act TEXT NOT NULL,
    run_id TEXT NOT NULL,
    mode TEXT NOT NULL,
    claimed_at TEXT NOT NULL,
    heartbeat_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
);
"""


def write_journal(directory, project_id, expires_at=None):
    """Builds a tiny sqlite fixture with the real act_lease columns. `expires_at=None` writes no
    Journal at all (never-run Project)."""
    path = directory / "journals" / f"{project_id}.db"
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path)
    try:
        connection.executescript(ACT_LEASE_SCHEMA)
        if expires_at is not None:
            stamp = expires_at.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            connection.execute(
                "INSERT INTO act_lease (id, act, run_id, mode, claimed_at, heartbeat_at, expires_at) "
                "VALUES (1, 'author', 'run-1', 'rehearsal', ?, ?, ?)",
                (stamp, stamp, stamp),
            )
        connection.commit()
    finally:
        connection.close()
    return path


TEAM = {"id": "team-1", "key": "SCRATCH"}
OTHER_TEAM = {"id": "team-2", "key": "OTHER"}


class ScratchLinearTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.configuration_directory = Path(self._tmp.name)
        write_machine_config(self.configuration_directory)
        self.keychain = FakeKeychain([fresh_pair()])

    def run_command(self, func, args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            try:
                code = func(args, self.configuration_directory, self.transport, keychain_reader=self.keychain)
            except scratch_linear.SetupFailed as error:
                print(f"scratch-linear: cannot run: {error}", file=stderr)
                code = 2
        return code, stdout.getvalue(), stderr.getvalue()

    def set_graphql_handler(self, handler):
        self.transport = FakeTransport(handler)


class BearerTokenTests(ScratchLinearTestCase):
    def test_graphql_uses_bearer_token_from_the_keychain(self):
        def handler(query, variables):
            return data_response({"teams": {"nodes": [TEAM]}})
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=None)
        self.run_command(scratch_linear.check_command, args)
        json_requests = [r for r in self.transport.requests if r[0] == "json"]
        self.assertTrue(json_requests)
        _, _, _, headers = json_requests[0]
        self.assertEqual(headers["Authorization"], f"Bearer {TOKEN}")

    def test_stale_token_refreshes_then_reads_the_new_pair(self):
        """A stale pair triggers `yh doctor --check linear --json` (here, a no-op `/usr/bin/true`),
        then one re-read of the Keychain, which answers with a fresh pair naming a new token."""
        self.keychain = FakeKeychain([stale_pair(token="old-token"), fresh_pair(token="new-token")])

        def handler(query, variables):
            return data_response({"teams": {"nodes": [TEAM]}})
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=None)
        self.run_command(scratch_linear.check_command, args)
        _, _, _, headers = [r for r in self.transport.requests if r[0] == "json"][0]
        self.assertEqual(headers["Authorization"], "Bearer new-token")
        self.assertEqual(self.keychain.calls, 2)

    def test_still_stale_after_refresh_is_setup_failed(self):
        self.keychain = FakeKeychain([stale_pair()])

        def handler(query, variables):
            raise AssertionError("no request should be sent with no working token")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=None)
        code, out, err = self.run_command(scratch_linear.check_command, args)
        self.assertEqual(code, 2)
        self.assertIn("no working Linear installation on this Mac; run yh setup --install-linear", err)

    def test_missing_pair_is_setup_failed(self):
        self.keychain = FakeKeychain([])

        def handler(query, variables):
            raise AssertionError("no request should be sent with no token pair at all")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=None)
        code, out, err = self.run_command(scratch_linear.check_command, args)
        self.assertEqual(code, 2)
        self.assertIn("no working Linear installation on this Mac", err)


class TokenNeverPrintedTests(ScratchLinearTestCase):
    def test_token_never_in_output_on_success(self):
        def handler(query, variables):
            return data_response({"teams": {"nodes": [TEAM]}})
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=None)
        code, out, err = self.run_command(scratch_linear.check_command, args)
        self.assertNotIn(TOKEN, out)
        self.assertNotIn(TOKEN, err)

    def test_token_never_in_output_on_graphql_error(self):
        def handler(query, variables):
            return 200, {"errors": [{"message": "boom"}]}
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=None)
        code, out, err = self.run_command(scratch_linear.check_command, args)
        self.assertNotIn(TOKEN, out)
        self.assertNotIn(TOKEN, err)
        self.assertEqual(code, 1)


class CheckCommandTests(ScratchLinearTestCase):
    def test_check_passes(self):
        write_project(self.configuration_directory, "proj-a", "lp-a")

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            if "project(id:" in query:
                return data_response({"project": {"id": "lp-a", "name": "A", "teams": {"nodes": [TEAM]}}})
            if "issues(" in query:
                return data_response({"issues": {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}})
            raise AssertionError(f"unexpected query: {query}")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=None)
        code, out, err = self.run_command(scratch_linear.check_command, args)
        self.assertEqual(code, 0, out + err)
        self.assertIn("PASS team SCRATCH exists", out)
        self.assertIn("PASS Project proj-a", out)

    def test_check_fails_when_project_in_second_team(self):
        write_project(self.configuration_directory, "proj-a", "lp-a")

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            if "project(id:" in query:
                return data_response(
                    {"project": {"id": "lp-a", "name": "A", "teams": {"nodes": [TEAM, OTHER_TEAM]}}}
                )
            if "issues(" in query:
                return data_response({"issues": {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}})
            raise AssertionError(f"unexpected query: {query}")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=None)
        code, out, err = self.run_command(scratch_linear.check_command, args)
        self.assertEqual(code, 1)
        self.assertIn("FAIL Project proj-a", out)

    def test_check_team_missing(self):
        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": []}})
            raise AssertionError(f"unexpected query: {query}")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=[])
        code, out, err = self.run_command(scratch_linear.check_command, args)
        self.assertEqual(code, 1)
        self.assertIn("FAIL team SCRATCH exists", out)


class ResetGuardTests(ScratchLinearTestCase):
    def test_reset_refuses_project_outside_scratch_team(self):
        write_project(self.configuration_directory, "proj-a", "lp-a")

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            if "project(id:" in query:
                return data_response(
                    {"project": {"id": "lp-a", "name": "A", "teams": {"nodes": [OTHER_TEAM]}}}
                )
            raise AssertionError(f"unexpected query: {query} (a mutation must never be sent)")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=["proj-a"], dry_run=False, keep_journal=False)
        code, out, err = self.run_command(scratch_linear.reset_command, args)
        self.assertEqual(code, 2)
        self.assertIn("cannot run", err)
        mutations = [r for r in self.transport.requests if r[0] == "json" and "issueArchive" in r[2]["query"]]
        self.assertEqual(mutations, [])

    def test_reset_refuses_live_act_lease_and_deletes_nothing(self):
        write_project(self.configuration_directory, "proj-a", "lp-a")
        future = datetime.now(timezone.utc) + timedelta(minutes=5)
        journal = write_journal(self.configuration_directory, "proj-a", expires_at=future)
        self.assertTrue(journal.exists())

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            if "project(id:" in query:
                return data_response({"project": {"id": "lp-a", "name": "A", "teams": {"nodes": [TEAM]}}})
            raise AssertionError(f"unexpected query: {query} (a mutation must never be sent)")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=["proj-a"], dry_run=False, keep_journal=False)
        code, out, err = self.run_command(scratch_linear.reset_command, args)
        self.assertEqual(code, 2)
        self.assertTrue(journal.exists(), "a refused reset must delete nothing")

    def test_reset_allows_expired_act_lease(self):
        write_project(self.configuration_directory, "proj-a", "lp-a")
        past = datetime.now(timezone.utc) - timedelta(minutes=5)
        write_journal(self.configuration_directory, "proj-a", expires_at=past)

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            if "project(id:" in query:
                return data_response({"project": {"id": "lp-a", "name": "A", "teams": {"nodes": [TEAM]}}})
            if "issues(" in query:
                return data_response({"issues": {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}})
            raise AssertionError(f"unexpected query: {query}")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=["proj-a"], dry_run=False, keep_journal=False)
        code, out, err = self.run_command(scratch_linear.reset_command, args)
        self.assertEqual(code, 0, out + err)

    def test_reset_missing_linear_project_field(self):
        write_toml(self.configuration_directory / "projects" / "proj-a.toml", "name = \"A\"\n")

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            raise AssertionError(f"unexpected query: {query} (a mutation must never be sent)")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=["proj-a"], dry_run=False, keep_journal=False)
        code, out, err = self.run_command(scratch_linear.reset_command, args)
        self.assertEqual(code, 2)


class ResetArchiveTests(ScratchLinearTestCase):
    def _fixed_pages(self, pages, teams=(TEAM,)):
        """A handler serving `pages` (a list of id-lists) for issues(), one page per call, and
        succeeding every issueArchive mutation."""
        state = {"page": 0, "archived": set()}

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            if "project(id:" in query:
                return data_response({"project": {"id": "lp-a", "name": "A", "teams": {"nodes": list(teams)}}})
            if "issueArchive" in query:
                state["archived"].add(variables["id"])
                return data_response({"issueArchive": {"success": True}})
            if "issues(" in query:
                remaining = [i for page in pages for i in page if i not in state["archived"]]
                index = state["page"]
                state["page"] += 1
                page = pages[index] if index < len(pages) else []
                page = [i for i in page if i not in state["archived"]]
                has_next = index + 1 < len(pages)
                return data_response({
                    "issues": {
                        "nodes": [{"id": i} for i in page],
                        "pageInfo": {"hasNextPage": has_next, "endCursor": str(index) if has_next else None},
                    }
                })
            raise AssertionError(f"unexpected query: {query}")
        return handler, state

    def test_reset_archives_across_two_pages(self):
        write_project(self.configuration_directory, "proj-a", "lp-a")
        handler, state = self._fixed_pages([["issue-1", "issue-2"], ["issue-3"]])
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=["proj-a"], dry_run=False, keep_journal=True)
        code, out, err = self.run_command(scratch_linear.reset_command, args)
        self.assertEqual(code, 0, out + err)
        self.assertIn("archived 3 issue(s)", out)
        self.assertEqual(state["archived"], {"issue-1", "issue-2", "issue-3"})

    def test_reset_tolerates_auto_archived_child(self):
        """archive_issue on the child raises a GraphQL error (already archived by its parent); a
        re-listing shows it is no longer present, so the reset still succeeds."""
        write_project(self.configuration_directory, "proj-a", "lp-a")
        calls = {"pass": 0}

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            if "project(id:" in query:
                return data_response({"project": {"id": "lp-a", "name": "A", "teams": {"nodes": [TEAM]}}})
            if "issueArchive" in query:
                if variables["id"] == "child" and calls["pass"] == 0:
                    return 200, {"errors": [{"message": "already archived"}]}
                return data_response({"issueArchive": {"success": True}})
            if "issues(" in query:
                calls["pass"] += 1
                if calls["pass"] == 1:
                    return data_response({
                        "issues": {
                            "nodes": [{"id": "parent"}, {"id": "child"}],
                            "pageInfo": {"hasNextPage": False, "endCursor": None},
                        }
                    })
                return data_response(
                    {"issues": {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}}
                )
            raise AssertionError(f"unexpected query: {query}")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=["proj-a"], dry_run=False, keep_journal=True)
        code, out, err = self.run_command(scratch_linear.reset_command, args)
        self.assertEqual(code, 0, out + err)
        self.assertIn("archived 2 issue(s)", out)

    def test_reset_exceeds_pass_cap(self):
        write_project(self.configuration_directory, "proj-a", "lp-a")

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            if "project(id:" in query:
                return data_response({"project": {"id": "lp-a", "name": "A", "teams": {"nodes": [TEAM]}}})
            if "issueArchive" in query:
                return data_response({"issueArchive": {"success": False}})
            if "issues(" in query:
                return data_response(
                    {"issues": {"nodes": [{"id": "stuck"}], "pageInfo": {"hasNextPage": False, "endCursor": None}}}
                )
            raise AssertionError(f"unexpected query: {query}")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=["proj-a"], dry_run=False, keep_journal=True)
        code, out, err = self.run_command(scratch_linear.reset_command, args)
        self.assertEqual(code, 1)
        self.assertIn("FAILED", err)

    def test_dry_run_sends_no_mutation_and_keeps_journal(self):
        write_project(self.configuration_directory, "proj-a", "lp-a")
        write_journal(self.configuration_directory, "proj-a", expires_at=None)

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            if "project(id:" in query:
                return data_response({"project": {"id": "lp-a", "name": "A", "teams": {"nodes": [TEAM]}}})
            if "issues(" in query:
                return data_response(
                    {"issues": {"nodes": [{"id": "x"}], "pageInfo": {"hasNextPage": False, "endCursor": None}}}
                )
            if "issueArchive" in query:
                raise AssertionError("dry-run must send no mutation")
            raise AssertionError(f"unexpected query: {query}")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=["proj-a"], dry_run=True, keep_journal=False)
        code, out, err = self.run_command(scratch_linear.reset_command, args)
        self.assertEqual(code, 0, out + err)
        self.assertIn("would archive 1 issue(s) (dry-run)", out)
        journal = scratch_linear.journal_path(self.configuration_directory, "proj-a")
        self.assertTrue(journal.exists())

    def test_second_run_is_a_no_op(self):
        write_project(self.configuration_directory, "proj-a", "lp-a")

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            if "project(id:" in query:
                return data_response({"project": {"id": "lp-a", "name": "A", "teams": {"nodes": [TEAM]}}})
            if "issues(" in query:
                return data_response(
                    {"issues": {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}}
                )
            if "issueArchive" in query:
                raise AssertionError("nothing to archive: no mutation should be sent")
            raise AssertionError(f"unexpected query: {query}")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=["proj-a"], dry_run=False, keep_journal=False)
        code, out, err = self.run_command(scratch_linear.reset_command, args)
        self.assertEqual(code, 0, out + err)
        self.assertIn("nothing to archive", out)
        self.assertIn("Journal none", out)

    def test_keep_journal_flag(self):
        write_project(self.configuration_directory, "proj-a", "lp-a")
        write_journal(self.configuration_directory, "proj-a", expires_at=None)

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            if "project(id:" in query:
                return data_response({"project": {"id": "lp-a", "name": "A", "teams": {"nodes": [TEAM]}}})
            if "issues(" in query:
                return data_response(
                    {"issues": {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}}
                )
            raise AssertionError(f"unexpected query: {query}")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=["proj-a"], dry_run=False, keep_journal=True)
        code, out, err = self.run_command(scratch_linear.reset_command, args)
        self.assertEqual(code, 0, out + err)
        self.assertIn("Journal kept", out)
        journal = scratch_linear.journal_path(self.configuration_directory, "proj-a")
        self.assertTrue(journal.exists())

    def test_journal_removal_deletes_only_project_files(self):
        write_project(self.configuration_directory, "proj-a", "lp-a")
        write_journal(self.configuration_directory, "proj-a", expires_at=None)
        journals_dir = self.configuration_directory / "journals"
        for suffix in ("-wal", "-shm"):
            (journals_dir / f"proj-a.db{suffix}").write_text("x")
        other = journals_dir / "proj-b.db"
        other.write_text("keep me")

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            if "project(id:" in query:
                return data_response({"project": {"id": "lp-a", "name": "A", "teams": {"nodes": [TEAM]}}})
            if "issues(" in query:
                return data_response(
                    {"issues": {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}}
                )
            raise AssertionError(f"unexpected query: {query}")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=["proj-a"], dry_run=False, keep_journal=False)
        code, out, err = self.run_command(scratch_linear.reset_command, args)
        self.assertEqual(code, 0, out + err)
        self.assertFalse((journals_dir / "proj-a.db").exists())
        self.assertFalse((journals_dir / "proj-a.db-wal").exists())
        self.assertFalse((journals_dir / "proj-a.db-shm").exists())
        self.assertTrue(other.exists())


class OnlyIssueArchiveMutationTests(ScratchLinearTestCase):
    def test_every_mutation_sent_in_the_suite_is_issue_archive(self):
        """Re-runs the full archive scenario and asserts every mutation recorded is issueArchive."""
        write_project(self.configuration_directory, "proj-a", "lp-a")

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            if "project(id:" in query:
                return data_response({"project": {"id": "lp-a", "name": "A", "teams": {"nodes": [TEAM]}}})
            if "issueArchive" in query:
                return data_response({"issueArchive": {"success": True}})
            if "issues(" in query:
                return data_response(
                    {"issues": {"nodes": [{"id": "x"}], "pageInfo": {"hasNextPage": False, "endCursor": None}}}
                )
            raise AssertionError(f"unexpected query: {query}")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=["proj-a"], dry_run=False, keep_journal=True)
        self.run_command(scratch_linear.reset_command, args)
        mutations = [r for r in self.transport.requests if r[0] == "json" and "mutation" in r[2]["query"]]
        self.assertTrue(mutations)
        for _, _, payload, _ in mutations:
            self.assertIn("issueArchive", payload["query"])
            self.assertNotIn("workflowState", payload["query"])
            self.assertNotIn("labelCreate", payload["query"])
            self.assertNotIn("projectUpdate", payload["query"])
            self.assertNotIn("teamCreate", payload["query"])
            self.assertNotIn("commentCreate", payload["query"])


class InvalidProjectIdTests(unittest.TestCase):
    def test_invalid_project_id_rejected_by_argparse(self):
        stderr = io.StringIO()
        with redirect_stderr(stderr), self.assertRaises(SystemExit) as context:
            scratch_linear.parse_arguments(["check", "--team", "SCRATCH", "--project", "bad id!"])
        self.assertEqual(context.exception.code, 2)
        self.assertIn("invalid Project id", stderr.getvalue())

    def test_invalid_project_id_rejected_for_reset(self):
        stderr = io.StringIO()
        with redirect_stderr(stderr), self.assertRaises(SystemExit) as context:
            scratch_linear.parse_arguments(["reset", "--team", "SCRATCH", "--project", "../etc"])
        self.assertEqual(context.exception.code, 2)


class InstallationSelectionTests(ScratchLinearTestCase):
    def two_installations(self):
        write_machine_config_with(self.configuration_directory, [
            installation_table("scratch", "keychain:linear-scratch", "ws-1", operator="op-1"),
            installation_table("my-ws", "keychain:linear-other", "ws-2"),
        ])

    def test_sole_entry_is_the_default(self):
        machine = scratch_linear.load_machine_config(self.configuration_directory)
        self.assertEqual(machine.name, "scratch")
        self.assertEqual(machine.credential, "keychain:linear-scratch")
        self.assertEqual(machine.workspace, "ws-scratch")
        self.assertEqual(machine.app_user, "app-scratch")
        self.assertIsNone(machine.operator)

    def test_named_selection_among_several(self):
        self.two_installations()
        machine = scratch_linear.load_machine_config(self.configuration_directory, "my-ws")
        self.assertEqual(machine.name, "my-ws")
        self.assertEqual(machine.credential, "keychain:linear-other")
        scratch = scratch_linear.load_machine_config(self.configuration_directory, "scratch")
        self.assertEqual(scratch.operator, "op-1")

    def test_zero_installations_is_refused(self):
        write_toml(self.configuration_directory / "config.toml", '[general]\nsomething = "x"\n')
        with self.assertRaises(scratch_linear.SetupFailed) as context:
            scratch_linear.load_machine_config(self.configuration_directory)
        self.assertEqual(
            str(context.exception), "no Linear installation in config.toml; run yh setup --install-linear"
        )

    def test_missing_config_file_is_refused(self):
        (self.configuration_directory / "config.toml").unlink()
        with self.assertRaises(scratch_linear.SetupFailed) as context:
            scratch_linear.load_machine_config(self.configuration_directory)
        self.assertIn("no Linear installation in config.toml", str(context.exception))

    def test_several_without_a_name_is_refused(self):
        self.two_installations()
        with self.assertRaises(scratch_linear.SetupFailed) as context:
            scratch_linear.load_machine_config(self.configuration_directory)
        message = str(context.exception)
        self.assertIn("my-ws", message)
        self.assertIn("scratch", message)
        self.assertIn("--installation <name>", message)

    def test_unknown_name_is_refused_naming_registered_ones(self):
        self.two_installations()
        with self.assertRaises(scratch_linear.SetupFailed) as context:
            scratch_linear.load_machine_config(self.configuration_directory, "nope")
        message = str(context.exception)
        self.assertIn("'nope'", message)
        self.assertIn("my-ws, scratch", message)

    def test_installation_flag_is_parsed(self):
        args = scratch_linear.parse_arguments(["--installation", "my-ws", "check", "--team", "SCRATCH"])
        self.assertEqual(args.installation, "my-ws")
        args = scratch_linear.parse_arguments(["check", "--team", "SCRATCH"])
        self.assertIsNone(args.installation)

    def test_flag_selects_the_keychain_account(self):
        self.two_installations()
        accounts = []

        def keychain(account):
            accounts.append(account)
            return fresh_pair()
        self.keychain = keychain

        def handler(query, variables):
            return data_response({"teams": {"nodes": [TEAM]}})
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=[], installation="my-ws")
        code, out, err = self.run_command(scratch_linear.check_command, args)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(accounts, ["linear-other"])

    def test_reset_refuses_a_project_on_another_installation(self):
        self.two_installations()
        write_project(self.configuration_directory, "proj-a", "lp-a", installation="my-ws")

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            raise AssertionError(f"unexpected query: {query} (nothing else may be sent)")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=["proj-a"], dry_run=False, keep_journal=False, installation="scratch")
        code, out, err = self.run_command(scratch_linear.reset_command, args)
        self.assertEqual(code, 2)
        self.assertIn("'my-ws'", err)
        self.assertIn("'scratch'", err)
        self.assertIn("nothing was changed", err)

    def test_check_fails_a_project_on_another_installation(self):
        self.two_installations()
        write_project(self.configuration_directory, "proj-a", "lp-a", installation="my-ws")

        def handler(query, variables):
            if "teams(" in query:
                return data_response({"teams": {"nodes": [TEAM]}})
            raise AssertionError(f"unexpected query: {query}")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=["proj-a"], installation="scratch")
        code, out, err = self.run_command(scratch_linear.check_command, args)
        self.assertEqual(code, 1)
        self.assertIn("FAIL Project proj-a", out)
        self.assertIn("'my-ws'", out)


class CredentialReferenceTests(ScratchLinearTestCase):
    def test_unsupported_credential_reference_is_setup_failed(self):
        write_machine_config(self.configuration_directory, credential="env:LINEAR_SECRET")

        def handler(query, variables):
            raise AssertionError("no request should be sent with an unsupported credential reference")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=None)
        code, out, err = self.run_command(scratch_linear.check_command, args)
        self.assertEqual(code, 2)
        self.assertIn("unsupported credential reference", err)


if __name__ == "__main__":
    unittest.main()
