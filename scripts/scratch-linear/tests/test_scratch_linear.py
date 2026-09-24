#!/usr/bin/env python3
"""
Unit tests for scratch_linear.py — fully offline, a fake HTTP transport records every request and
no test ever touches the network or the Keychain.
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


SECRET = "s3cr3t-value-never-printed"
TOKEN = "tok3n-value-never-printed"


class FakeTransport:
    """Records every request. `token_status`/`token_body` script the OAuth endpoint; `graphql_script`
    is a list of (matcher, response) pairs consumed... actually a callable taking (query, variables)
    and returning a dict payload (or raising to simulate an HTTP-level failure)."""

    def __init__(self, graphql_handler, token_status=200, token_body=None):
        self.requests = []
        self.token_status = token_status
        self.token_body = token_body if token_body is not None else {"access_token": TOKEN}
        self.graphql_handler = graphql_handler

    def post_form(self, url, fields):
        self.requests.append(("form", url, fields, None))
        return self.token_status, json.dumps(self.token_body)

    def post_json(self, url, payload, headers=None):
        self.requests.append(("json", url, payload, headers))
        query = payload["query"]
        variables = payload["variables"]
        status, body = self.graphql_handler(query, variables)
        return status, json.dumps(body)


def data_response(data):
    return 200, {"data": data}


class Args:
    def __init__(self, **kwargs):
        self.client_id = kwargs.pop("client_id", None)
        self.__dict__.update(kwargs)


def write_toml(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def write_machine_config(directory, client_id="scratch-client-id", credential="keychain:linear"):
    write_toml(
        directory / "config.toml",
        f'[linear]\nclient_id = "{client_id}"\ncredential = "{credential}"\n',
    )


def write_project(directory, project_id, linear_project_id):
    write_toml(directory / "projects" / f"{project_id}.toml", f'linear_project = "{linear_project_id}"\n')


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

    def run_command(self, func, args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            try:
                code = func(args, self.configuration_directory, self.transport, lambda account: SECRET)
            except scratch_linear.SetupFailed as error:
                print(f"scratch-linear: cannot run: {error}", file=stderr)
                code = 2
        return code, stdout.getvalue(), stderr.getvalue()

    def set_graphql_handler(self, handler):
        self.transport = FakeTransport(handler)


class TokenRequestTests(ScratchLinearTestCase):
    def test_token_request_form_fields(self):
        def handler(query, variables):
            return data_response({"teams": {"nodes": [TEAM]}})
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=None)
        self.run_command(scratch_linear.check_command, args)
        form_requests = [r for r in self.transport.requests if r[0] == "form"]
        self.assertEqual(len(form_requests), 1)
        _, url, fields, _ = form_requests[0]
        self.assertEqual(url, scratch_linear.TOKEN_URL)
        self.assertEqual(fields["client_id"], "scratch-client-id")
        self.assertEqual(fields["client_secret"], SECRET)
        self.assertEqual(fields["grant_type"], "client_credentials")
        self.assertEqual(fields["scope"], "read,write")

    def test_graphql_uses_bearer_token(self):
        def handler(query, variables):
            return data_response({"teams": {"nodes": [TEAM]}})
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=None)
        self.run_command(scratch_linear.check_command, args)
        json_requests = [r for r in self.transport.requests if r[0] == "json"]
        self.assertTrue(json_requests)
        _, _, _, headers = json_requests[0]
        self.assertEqual(headers["Authorization"], f"Bearer {TOKEN}")


class SecretNeverPrintedTests(ScratchLinearTestCase):
    def test_secret_never_in_output_on_success(self):
        def handler(query, variables):
            return data_response({"teams": {"nodes": [TEAM]}})
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=None)
        code, out, err = self.run_command(scratch_linear.check_command, args)
        self.assertNotIn(SECRET, out)
        self.assertNotIn(SECRET, err)
        self.assertNotIn(TOKEN, out)
        self.assertNotIn(TOKEN, err)

    def test_secret_never_in_output_on_graphql_error(self):
        def handler(query, variables):
            return 200, {"errors": [{"message": "boom"}]}
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=None)
        code, out, err = self.run_command(scratch_linear.check_command, args)
        self.assertNotIn(SECRET, out)
        self.assertNotIn(SECRET, err)
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


class CredentialAndClientIdTests(ScratchLinearTestCase):
    def test_missing_client_id_is_setup_failed(self):
        write_toml(self.configuration_directory / "config.toml", '[linear]\ncredential = "keychain:linear"\n')

        def handler(query, variables):
            raise AssertionError("no request should be sent without a client id")
        self.set_graphql_handler(handler)
        args = Args(team="SCRATCH", project=None)
        code, out, err = self.run_command(scratch_linear.check_command, args)
        self.assertEqual(code, 2)
        self.assertIn("no Linear client id", err)

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
