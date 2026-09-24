import json
import sqlite3
import subprocess
import sys
import tempfile
import tomllib
import unittest
from datetime import date
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import suite_env  # noqa: E402


# MARK: - Project TOML rendering


class RenderProjectTomlTests(unittest.TestCase):
    def test_default_keys_round_trip(self):
        text = suite_env.render_project_toml(
            project_id="rehearsal-suite-a",
            name="Rehearsal Suite A",
            linear_project="11111111-1111-4111-8111-111111111111",
            spec_source="/tmp/spec",
            repos=[
                {"name": "fixture-backend", "path": "/tmp/backend", "role": "backend"},
                {"name": "fixture-web", "path": "/tmp/web", "role": "web"},
            ],
        )
        data = tomllib.loads(text)
        self.assertEqual(data["id"], "rehearsal-suite-a")
        self.assertEqual(data["name"], "Rehearsal Suite A")
        self.assertEqual(data["linear_project"], "11111111-1111-4111-8111-111111111111")
        self.assertEqual(data["spec_source"], "/tmp/spec")
        self.assertEqual(len(data["repos"]), 2)
        self.assertEqual(data["repos"][0]["check"], "true")
        self.assertNotIn("protected_paths", data["repos"][0])
        self.assertEqual(data["limits"], suite_env.DEFAULT_LIMITS)
        self.assertEqual(data["schedule"], suite_env.DEFAULT_SCHEDULE)
        self.assertEqual(len(data["routing"]), 1)
        self.assertEqual(data["routing"][0]["route"], "claude/sonnet/medium")
        self.assertEqual(data["routing"][0]["fallbacks"], ["claude/opus/high"])

    def test_overrides(self):
        text = suite_env.render_project_toml(
            project_id="rehearsal-suite-a",
            name="A",
            linear_project="lp",
            spec_source="/tmp/spec",
            repos=[
                {
                    "name": "fixture-backend", "path": "/tmp/backend", "role": "backend",
                    "check": "npm test", "protected_paths": ["migrations/"],
                },
            ],
            limits={"attempts_per_card": 1},
            schedule={"build_every_minutes": 5},
            route="claude/opus/high",
            fallbacks=("claude/sonnet/medium", "claude/opus/high"),
        )
        data = tomllib.loads(text)
        self.assertEqual(data["repos"][0]["check"], "npm test")
        self.assertEqual(data["repos"][0]["protected_paths"], ["migrations/"])
        self.assertEqual(data["limits"]["attempts_per_card"], 1)
        self.assertEqual(data["limits"]["review_rounds_max"], suite_env.DEFAULT_LIMITS["review_rounds_max"])
        self.assertEqual(data["schedule"]["build_every_minutes"], 5)
        self.assertEqual(data["routing"][0]["fallbacks"], ["claude/sonnet/medium", "claude/opus/high"])

    def test_escapes_quotes_and_backslashes(self):
        text = suite_env.render_project_toml(
            project_id="p",
            name='Name with "quotes" and \\backslash',
            linear_project="lp",
            spec_source="/tmp/spec",
            repos=[{"name": "r", "path": "/tmp/r", "role": "backend"}],
        )
        data = tomllib.loads(text)
        self.assertEqual(data["name"], 'Name with "quotes" and \\backslash')


# MARK: - night(k)


class NightTests(unittest.TestCase):
    def test_night_one_is_thirty_days_before_today(self):
        today = date(2026, 9, 24)
        self.assertEqual(suite_env.night(1, today=today), "2026-08-25")

    def test_night_two_is_the_day_after_night_one(self):
        today = date(2026, 9, 24)
        self.assertEqual(suite_env.night(2, today=today), "2026-08-26")

    def test_night_five(self):
        today = date(2026, 1, 1)
        self.assertEqual(suite_env.night(5, today=today), "2025-12-06")


# MARK: - feature_branch (sanitiser)


class FeatureBranchTests(unittest.TestCase):
    def test_replaces_non_word_characters(self):
        branch = suite_env.feature_branch("rehearsal-suite-a", "Add Cool Feature!!")
        self.assertEqual(branch, "yh-rehearsal-suite-a-Add-Cool-Feature")

    def test_collapses_runs_of_spaces(self):
        branch = suite_env.feature_branch("proj", "a   b   c")
        self.assertEqual(branch, "yh-proj-a-b-c")

    def test_empty_falls_back_to_unnamed(self):
        branch = suite_env.feature_branch("proj", "!!!")
        self.assertEqual(branch, "yh-proj-unnamed")


# MARK: - yh argument building


class BuildActArgsTests(unittest.TestCase):
    def test_defaults(self):
        args = suite_env.build_act_args("author", project="rehearsal-suite-a")
        self.assertEqual(args, ["author", "--project", "rehearsal-suite-a", "--force", "--rehearsal"])

    def test_night_and_feature(self):
        args = suite_env.build_act_args(
            "author", project="rehearsal-suite-a", night="2026-08-25", feature="My Feature"
        )
        self.assertEqual(
            args,
            [
                "author", "--project", "rehearsal-suite-a", "--force", "--rehearsal",
                "--night", "2026-08-25", "--feature", "My Feature",
            ],
        )

    def test_result_fixture_lane_form(self):
        args = suite_env.build_act_args(
            "build", project="p", result_fixtures=[("worker", "worker-completed")]
        )
        self.assertIn("--result-fixture", args)
        self.assertIn("worker=worker-completed", args)

    def test_result_fixture_card_scoped_form(self):
        args = suite_env.build_act_args(
            "build", project="p", result_fixtures=[("worker", "ISSUE-123", "worker-failed")]
        )
        self.assertIn("worker@ISSUE-123=worker-failed", args)

    def test_multiple_result_fixtures_preserve_order(self):
        args = suite_env.build_act_args(
            "build", project="p",
            result_fixtures=[("selection", "selection-selected"), ("breakdown", "breakdown-drafted")],
        )
        fixture_values = [args[i + 1] for i, token in enumerate(args) if token == "--result-fixture"]
        self.assertEqual(fixture_values, ["selection=selection-selected", "breakdown=breakdown-drafted"])

    def test_invalid_result_fixture_shape_raises(self):
        with self.assertRaises(ValueError):
            suite_env.build_act_args("build", project="p", result_fixtures=[("only-one",)])

    def test_no_force_no_rehearsal(self):
        args = suite_env.build_act_args("author", project="p", force=False, rehearsal=False)
        self.assertEqual(args, ["author", "--project", "p"])


class BuildRehearseArgsTests(unittest.TestCase):
    def test_basic(self):
        args = suite_env.build_rehearse_args(project="rehearsal-suite-a", night="2026-08-25")
        self.assertEqual(args, ["rehearse", "--project", "rehearsal-suite-a", "--night", "2026-08-25"])

    def test_with_result_fixtures(self):
        args = suite_env.build_rehearse_args(
            project="p", night="2026-08-25", result_fixtures=[("selection", "selection-no-selectable-feature")]
        )
        self.assertIn("--result-fixture", args)
        self.assertIn("selection=selection-no-selectable-feature", args)


# MARK: - Journal snapshot helpers


class JournalSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.db_path = Path(self.tmp.name) / "journal.db"
        connection = sqlite3.connect(str(self.db_path))
        connection.executescript(
            """
            CREATE TABLE night (
                id INTEGER PRIMARY KEY, project_id TEXT, night_start TEXT, state TEXT, verdict TEXT,
                night_card_issue_id TEXT
            );
            CREATE TABLE card (id INTEGER PRIMARY KEY, cycle_id INTEGER, issue_id TEXT, state TEXT);
            CREATE TABLE feature (id INTEGER PRIMARY KEY, issue_id TEXT, branch TEXT, state TEXT);
            CREATE TABLE worktree (
                id INTEGER PRIMARY KEY, feature_id INTEGER, repository TEXT, path TEXT, released_at TEXT
            );
            CREATE TABLE event (
                id INTEGER PRIMARY KEY, night_id INTEGER, act TEXT, run_id TEXT, type TEXT,
                occurred_at TEXT, payload TEXT
            );
            INSERT INTO night VALUES (1, 'rehearsal-suite-a', '2026-08-25', 'closed', 'idle', 'ISSUE-1');
            INSERT INTO card VALUES (1, 1, 'ISSUE-10', 'Done');
            INSERT INTO feature VALUES (1, 'ISSUE-9', 'yh-rehearsal-suite-a-feature-1', 'landed');
            INSERT INTO worktree VALUES (1, 1, 'fixture-backend', '/tmp/wt', NULL);
            INSERT INTO event VALUES (1, 1, 'build', 'run-1', 'ActIdle', '2026-08-25T00:00:00Z',
                                       '{"reason": "no_feature_in_flight"}');
            INSERT INTO event VALUES (2, 1, 'land', 'run-1', 'ActIdle', '2026-08-25T00:01:00Z',
                                       '{"reason": "no_feature_in_flight"}');
            INSERT INTO event VALUES (3, 1, 'author', 'run-1', 'AuthoringNoWorkAvailable',
                                       '2026-08-25T00:02:00Z', NULL);
            """
        )
        connection.commit()
        connection.close()
        self.snapshot = suite_env.JournalSnapshot(self.db_path)
        self.addCleanup(self.snapshot.close)

    def test_events_all(self):
        events = self.snapshot.events()
        self.assertEqual(len(events), 3)
        self.assertEqual(events[0]["type"], "ActIdle")

    def test_events_filtered_by_type_parses_payload(self):
        events = self.snapshot.events(type="ActIdle")
        self.assertEqual(len(events), 2)
        self.assertEqual(events[0]["payload"], {"reason": "no_feature_in_flight"})
        self.assertEqual(events[0]["act"], "build")
        self.assertEqual(events[1]["act"], "land")

    def test_events_with_no_payload_parses_to_empty_dict(self):
        events = self.snapshot.events(type="AuthoringNoWorkAvailable")
        self.assertEqual(events[0]["payload"], {})

    def test_cards(self):
        cards = self.snapshot.cards()
        self.assertEqual(len(cards), 1)
        self.assertEqual(cards[0]["state"], "Done")

    def test_features(self):
        features = self.snapshot.features()
        self.assertEqual(features[0]["branch"], "yh-rehearsal-suite-a-feature-1")

    def test_nights(self):
        nights = self.snapshot.nights()
        self.assertEqual(nights[0]["verdict"], "idle")

    def test_worktrees(self):
        worktrees = self.snapshot.worktrees()
        self.assertEqual(worktrees[0]["repository"], "fixture-backend")
        self.assertIsNone(worktrees[0]["released_at"])

    def test_night_id_found_and_missing(self):
        self.assertEqual(self.snapshot.night_id("2026-08-25"), 1)
        self.assertIsNone(self.snapshot.night_id("2026-08-26"))


# MARK: - Operator client


class FakeTransport:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def post_json(self, url, payload, headers=None):
        self.calls.append({"url": url, "payload": payload, "headers": headers})
        return self.responses.pop(0)


class ResetProjectTests(unittest.TestCase):
    def test_reset_skips_primary_checkout_worktree(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name) / "root"
        project_dir = root / "rehearsal-suite-a"
        clone_path = project_dir / "repos" / "fixture-backend"
        clone_path.mkdir(parents=True)
        manifest = {"repos": [{"name": "fixture-backend", "path": str(clone_path), "role": "backend"}]}
        project_dir.mkdir(parents=True, exist_ok=True)
        (project_dir / "manifest.json").write_text(json.dumps(manifest))

        env = suite_env.make_environment(
            app=Path(tmp.name) / "App.app", team="YLH", root=root, work_directory=Path(tmp.name) / "work",
            configuration_directory=Path(tmp.name) / "config", act_timeout=60, transport=mock.Mock(),
        )
        worktrees = [
            {"id": "wt-main", "path": str(clone_path), "branch": "main"},
            {"id": "wt-feature", "path": "/tmp/orca/workspaces/fixture-backend/yh-a-f1", "branch": "yh-a-f1"},
        ]
        rebuilt_manifest = dict(manifest)
        reset_result = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.object(suite_env, "orca_worktree_list", return_value=worktrees), \
             mock.patch.object(suite_env, "orca_worktree_rm") as rm_mock, \
             mock.patch.object(suite_env.subprocess, "run", return_value=reset_result), \
             mock.patch.object(suite_env, "build_fixture_tree", return_value=rebuilt_manifest), \
             mock.patch.object(suite_env, "orca_repo_add") as add_mock:
            result = suite_env.reset_project(env, "rehearsal-suite-a")
        rm_mock.assert_called_once_with("wt-feature")
        self.assertEqual(result, rebuilt_manifest)
        add_mock.assert_called_once_with(str(clone_path))

    def test_reset_raises_setup_failed_when_scratch_linear_reset_fails(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name) / "root"
        env = suite_env.make_environment(
            app=Path(tmp.name) / "App.app", team="YLH", root=root, work_directory=Path(tmp.name) / "work",
            configuration_directory=Path(tmp.name) / "config", act_timeout=60, transport=mock.Mock(),
        )
        failure_result = mock.Mock(returncode=2, stdout="", stderr="guard failed")
        with mock.patch.object(suite_env.subprocess, "run", return_value=failure_result):
            with self.assertRaises(suite_env.SetupFailed) as ctx:
                suite_env.reset_project(env, "rehearsal-suite-a")
        self.assertIn("guard failed", str(ctx.exception))


class ReadOperatorIdentityTests(unittest.TestCase):
    def test_reads_operator_from_config_toml(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        config_dir = Path(tmp.name)
        (config_dir / "config.toml").write_text('[linear]\noperator = "user-123"\n')
        self.assertEqual(suite_env.read_operator_identity(config_dir), "user-123")

    def test_missing_file_returns_none(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.assertIsNone(suite_env.read_operator_identity(Path(tmp.name)))

    def test_missing_key_returns_none(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        config_dir = Path(tmp.name)
        (config_dir / "config.toml").write_text('[linear]\nclient_id = "cid"\n')
        self.assertIsNone(suite_env.read_operator_identity(config_dir))


class StandInCommitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        subprocess.run(
            ["git", "-c", "init.defaultBranch=main", "init", str(self.repo)],
            capture_output=True, check=True,
        )
        (self.repo / "README.md").write_text("hello\n")
        env = dict(os_environ_without_git_config())
        subprocess.run(["git", "add", "-A"], cwd=self.repo, env=env, capture_output=True, check=True)
        subprocess.run(
            ["git", "commit", "-m", "initial"], cwd=self.repo, env=env, capture_output=True, check=True
        )

    def test_writes_marker_and_commits_cleanly(self):
        sha = suite_env.stand_in_commit(self.repo, "night-2-fixture-backend")
        self.assertRegex(sha, r"^[0-9a-f]{40}$")
        self.assertTrue((self.repo / "STAND-IN-night-2-fixture-backend.md").exists())
        status = subprocess.run(
            ["git", "status", "--porcelain"], cwd=self.repo, capture_output=True, text=True
        )
        self.assertEqual(status.stdout.strip(), "")

    def test_uses_a_fixed_author_identity(self):
        suite_env.stand_in_commit(self.repo, "label")
        result = subprocess.run(
            ["git", "log", "-1", "--format=%an <%ae>"], cwd=self.repo, capture_output=True, text=True
        )
        self.assertEqual(
            result.stdout.strip(),
            f"{suite_env.STAND_IN_AUTHOR_NAME} <{suite_env.STAND_IN_AUTHOR_EMAIL}>",
        )


def os_environ_without_git_config():
    import os as _os
    env = dict(_os.environ)
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_AUTHOR_NAME"] = "Test"
    env["GIT_AUTHOR_EMAIL"] = "test@example.invalid"
    env["GIT_COMMITTER_NAME"] = "Test"
    env["GIT_COMMITTER_EMAIL"] = "test@example.invalid"
    return env


class ApplyFixtureTests(unittest.TestCase):
    def test_success_returns_stdout(self):
        result = mock.Mock(returncode=0, stdout="apply: predecessor-merged: fixture-backend: merged\n", stderr="")
        with mock.patch.object(suite_env.subprocess, "run", return_value=result) as run_mock:
            output = suite_env.apply_fixture(
                Path("/tmp/root"), "rehearsal-suite-a", "predecessor-merged", feature="Fixture Feature 2"
            )
        self.assertIn("merged", output)
        args = run_mock.call_args[0][0]
        self.assertIn("apply", args)
        self.assertIn("predecessor-merged", args)
        self.assertIn("--feature", args)
        self.assertIn("Fixture Feature 2", args)

    def test_repo_filter_is_repeated(self):
        result = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.object(suite_env.subprocess, "run", return_value=result) as run_mock:
            suite_env.apply_fixture(
                Path("/tmp/root"), "rehearsal-suite-a", "predecessor-merged",
                repo=["fixture-backend"], feature="F2",
            )
        args = run_mock.call_args[0][0]
        self.assertEqual(args.count("--repo"), 1)
        self.assertIn("fixture-backend", args)

    def test_failure_raises_setup_failed(self):
        result = mock.Mock(returncode=1, stdout="", stderr="conflict")
        with mock.patch.object(suite_env.subprocess, "run", return_value=result):
            with self.assertRaises(suite_env.SetupFailed) as ctx:
                suite_env.apply_fixture(Path("/tmp/root"), "rehearsal-suite-a", "mainline-moved")
        self.assertIn("conflict", str(ctx.exception))


class OperatorClientTests(unittest.TestCase):
    def test_authorization_header_has_no_bearer_prefix(self):
        transport = FakeTransport([(200, json.dumps({"data": {"viewer": {"id": "op-1"}}}))])
        client = suite_env.OperatorClient(transport, "personal-api-key")
        viewer_id = client.viewer_id()
        self.assertEqual(viewer_id, "op-1")
        self.assertEqual(transport.calls[0]["headers"], {"Authorization": "personal-api-key"})

    def test_reply_sends_variables(self):
        transport = FakeTransport([(200, json.dumps({"data": {"commentCreate": {"success": True}}}))])
        client = suite_env.OperatorClient(transport, "key")
        ok = client.reply("ISSUE-1", "COMMENT-1", "hello")
        self.assertTrue(ok)
        variables = transport.calls[0]["payload"]["variables"]
        self.assertEqual(variables, {"issueId": "ISSUE-1", "parentId": "COMMENT-1", "body": "hello"})

    def test_move_to_state_resolves_state_by_exact_name(self):
        transport = FakeTransport([
            (200, json.dumps({"data": {"issue": {"team": {"id": "team-1", "states": {"nodes": [
                {"id": "state-todo", "name": "Todo"}, {"id": "state-cancelled", "name": "Cancelled"},
            ]}}}}})),
            (200, json.dumps({"data": {"issueUpdate": {"success": True}}})),
        ])
        client = suite_env.OperatorClient(transport, "key")
        ok = client.move_to_state("ISSUE-1", "Cancelled")
        self.assertTrue(ok)
        second_variables = transport.calls[1]["payload"]["variables"]
        self.assertEqual(second_variables["stateId"], "state-cancelled")

    def test_move_to_state_unknown_name_raises(self):
        transport = FakeTransport([
            (200, json.dumps({"data": {"issue": {"team": {"id": "team-1", "states": {"nodes": [
                {"id": "state-todo", "name": "Todo"},
            ]}}}}})),
        ])
        client = suite_env.OperatorClient(transport, "key")
        with self.assertRaises(suite_env.scratch_linear.LinearError):
            client.move_to_state("ISSUE-1", "Nonexistent")

    def test_move_to_state_of_type_resolves_by_type_not_name(self):
        transport = FakeTransport([
            (200, json.dumps({"data": {"issue": {"team": {"id": "team-1", "states": {"nodes": [
                {"id": "state-todo", "name": "Todo", "type": "unstarted"},
                {"id": "state-cancelled", "name": "Canceled", "type": "canceled"},
            ]}}}}})),
            (200, json.dumps({"data": {"issueUpdate": {"success": True}}})),
        ])
        client = suite_env.OperatorClient(transport, "key")
        ok = client.move_to_state_of_type("ISSUE-1", "canceled")
        self.assertTrue(ok)
        self.assertEqual(transport.calls[1]["payload"]["variables"]["stateId"], "state-cancelled")

    def test_move_to_state_of_type_unknown_type_raises(self):
        transport = FakeTransport([
            (200, json.dumps({"data": {"issue": {"team": {"id": "team-1", "states": {"nodes": [
                {"id": "state-todo", "name": "Todo", "type": "unstarted"},
            ]}}}}})),
        ])
        client = suite_env.OperatorClient(transport, "key")
        with self.assertRaises(suite_env.scratch_linear.LinearError):
            client.move_to_state_of_type("ISSUE-1", "canceled")

    def test_replace_scope_line_edits_only_the_fenced_line(self):
        description = (
            "Some intro text.\n"
            "<!-- yh:managed:start -->\n"
            "**Scope:** old/path.sql\n"
            "Other managed line.\n"
            "<!-- yh:managed:end -->\n"
            "Trailer text.\n"
        )
        transport = FakeTransport([
            (200, json.dumps({"data": {"issue": {"description": description}}})),
            (200, json.dumps({"data": {"issueUpdate": {"success": True}}})),
        ])
        client = suite_env.OperatorClient(transport, "key")
        client.replace_scope_line("ISSUE-1", "**Scope:** migrations/0002_fixture.sql")
        new_description = transport.calls[1]["payload"]["variables"]["description"]
        self.assertIn("**Scope:** migrations/0002_fixture.sql", new_description)
        self.assertNotIn("old/path.sql", new_description)
        self.assertIn("Other managed line.", new_description)
        self.assertIn("Some intro text.", new_description)
        self.assertIn("Trailer text.", new_description)

    def test_replace_scope_line_refuses_when_block_absent(self):
        transport = FakeTransport([
            (200, json.dumps({"data": {"issue": {"description": "no managed block here"}}})),
        ])
        client = suite_env.OperatorClient(transport, "key")
        with self.assertRaises(suite_env.scratch_linear.LinearError):
            client.replace_scope_line("ISSUE-1", "**Scope:** x")

    def test_replace_scope_line_refuses_when_scope_line_absent(self):
        description = "<!-- yh:managed:start -->\nNo scope line here.\n<!-- yh:managed:end -->\n"
        transport = FakeTransport([
            (200, json.dumps({"data": {"issue": {"description": description}}})),
        ])
        client = suite_env.OperatorClient(transport, "key")
        with self.assertRaises(suite_env.scratch_linear.LinearError):
            client.replace_scope_line("ISSUE-1", "**Scope:** x")


# MARK: - Orca cleanup parsing


class LinearReaderTests(unittest.TestCase):
    class _Client:
        def __init__(self, result=None, error=None):
            self.result = result
            self.error = error

        def graphql(self, query, variables=None):
            if self.error:
                raise self.error
            return self.result

    def test_an_issue_linear_cannot_find_is_absent(self):
        error = suite_env.scratch_linear.LinearError("Linear GraphQL error: [{'message': 'Entity not found: Issue'}]")
        reader = suite_env.LinearReader(self._Client(error=error))
        self.assertIsNone(reader.issue("missing"))

    def test_any_other_error_propagates(self):
        error = suite_env.scratch_linear.LinearError("Linear GraphQL error: rate limited")
        reader = suite_env.LinearReader(self._Client(error=error))
        with self.assertRaises(suite_env.scratch_linear.LinearError):
            reader.issue("any")

    def test_a_found_issue_is_returned(self):
        reader = suite_env.LinearReader(self._Client(result={"issue": {"id": "i-1", "title": "T"}}))
        self.assertEqual(reader.issue("i-1"), {"id": "i-1", "title": "T"})


class OrcaFunctionsTests(unittest.TestCase):
    def _fake_run(self, returncode, stdout):
        result = mock.Mock()
        result.returncode = returncode
        result.stdout = stdout
        return result

    def test_worktree_list_parses_worktrees(self):
        payload = {"ok": True, "result": {"worktrees": [{"id": "wt-1", "path": "/tmp/a"}]}}
        with mock.patch.object(suite_env.subprocess, "run", return_value=self._fake_run(0, json.dumps(payload))):
            worktrees = suite_env.orca_worktree_list("/tmp/a")
        self.assertEqual(worktrees, [{"id": "wt-1", "path": "/tmp/a"}])

    def test_worktree_list_raises_on_failure(self):
        payload = {"ok": False, "error": {"code": "boom", "message": "boom"}}
        with mock.patch.object(suite_env.subprocess, "run", return_value=self._fake_run(1, json.dumps(payload))):
            with self.assertRaises(suite_env.SetupFailed):
                suite_env.orca_worktree_list("/tmp/a")

    def test_worktree_list_of_an_unregistered_repository_is_empty(self):
        payload = {"ok": False, "error": {"code": "repo_not_found", "message": "repo_not_found"}}
        with mock.patch.object(suite_env.subprocess, "run", return_value=self._fake_run(1, json.dumps(payload))):
            self.assertEqual(suite_env.orca_worktree_list("/tmp/a"), [])

    def test_worktree_rm_tolerates_not_found(self):
        payload = {"ok": False, "error": {"code": "not_found", "message": "worktree not found"}}
        with mock.patch.object(suite_env.subprocess, "run", return_value=self._fake_run(1, json.dumps(payload))):
            result = suite_env.orca_worktree_rm("wt-1")
        self.assertFalse(result)

    def test_worktree_rm_raises_on_other_failure(self):
        payload = {"ok": False, "error": {"code": "boom", "message": "disk full"}}
        with mock.patch.object(suite_env.subprocess, "run", return_value=self._fake_run(1, json.dumps(payload))):
            with self.assertRaises(suite_env.SetupFailed):
                suite_env.orca_worktree_rm("wt-1")

    def test_repo_add_tolerates_already_registered(self):
        payload = {"ok": False, "error": {"code": "exists", "message": "repository already registered"}}
        with mock.patch.object(suite_env.subprocess, "run", return_value=self._fake_run(1, json.dumps(payload))):
            result = suite_env.orca_repo_add("/tmp/a")
        self.assertFalse(result)

    def test_repo_add_success(self):
        payload = {"ok": True, "result": {}}
        with mock.patch.object(suite_env.subprocess, "run", return_value=self._fake_run(0, json.dumps(payload))):
            result = suite_env.orca_repo_add("/tmp/a")
        self.assertTrue(result)

    def test_is_primary_checkout_matches_clone_path(self):
        worktree = {"id": "wt-main", "path": "/tmp/fixtures/repos/fixture-backend", "branch": "main"}
        self.assertTrue(suite_env.is_primary_checkout(worktree, "/tmp/fixtures/repos/fixture-backend"))

    def test_is_primary_checkout_false_for_a_feature_worktree(self):
        worktree = {"id": "wt-feature", "path": "/tmp/orca/workspaces/fixture-backend/yh-a-f1", "branch": "yh-a-f1"}
        self.assertFalse(suite_env.is_primary_checkout(worktree, "/tmp/fixtures/repos/fixture-backend"))

    def test_reset_skips_the_primary_checkout_and_removes_the_rest(self):
        clone_path = "/tmp/fixtures/repos/fixture-backend"
        worktrees = [
            {"id": "wt-main", "path": clone_path, "branch": "main"},
            {"id": "wt-feature", "path": "/tmp/orca/workspaces/fixture-backend/yh-a-f1", "branch": "yh-a-f1"},
        ]
        with mock.patch.object(suite_env, "orca_worktree_list", return_value=worktrees) as list_mock, \
             mock.patch.object(suite_env, "orca_worktree_rm") as rm_mock:
            for worktree in list_mock(clone_path):
                if suite_env.is_primary_checkout(worktree, clone_path):
                    continue
                suite_env.orca_worktree_rm(worktree["id"])
        rm_mock.assert_called_once_with("wt-feature")

    def test_status_ready(self):
        payload = {
            "ok": True,
            "result": {"app": {"running": True}, "runtime": {"state": "ready", "reachable": True}},
        }
        with mock.patch.object(suite_env.subprocess, "run", return_value=self._fake_run(0, json.dumps(payload))):
            self.assertTrue(suite_env.orca_status_ready())

    def test_status_not_ready_when_state_is_not_ready(self):
        payload = {
            "ok": True,
            "result": {"app": {"running": True}, "runtime": {"state": "starting", "reachable": True}},
        }
        with mock.patch.object(suite_env.subprocess, "run", return_value=self._fake_run(0, json.dumps(payload))):
            self.assertFalse(suite_env.orca_status_ready())

    def test_status_not_ready_when_unreachable(self):
        payload = {
            "ok": True,
            "result": {"app": {"running": True}, "runtime": {"state": "ready", "reachable": False}},
        }
        with mock.patch.object(suite_env.subprocess, "run", return_value=self._fake_run(0, json.dumps(payload))):
            self.assertFalse(suite_env.orca_status_ready())

    def test_status_not_ready_when_ok_is_false(self):
        payload = {"ok": False, "error": {"code": "not_ready", "message": "runtime not ready"}}
        with mock.patch.object(suite_env.subprocess, "run", return_value=self._fake_run(0, json.dumps(payload))):
            self.assertFalse(suite_env.orca_status_ready())

    def test_orca_not_installed_raises_setup_failed(self):
        with mock.patch.object(suite_env.subprocess, "run", side_effect=FileNotFoundError()):
            with self.assertRaises(suite_env.SetupFailed):
                suite_env.orca_status_ready()


# MARK: - Preflight ordering


class PreflightOrderingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.app = Path(self.tmp.name) / "Yellowhammer.app"
        self.configuration_directory = Path(self.tmp.name) / "config"
        self.configuration_directory.mkdir()
        self.env = suite_env.make_environment(
            app=self.app, team="YLH", root=Path(self.tmp.name) / "root",
            work_directory=Path(self.tmp.name) / "work",
            configuration_directory=self.configuration_directory, act_timeout=60,
            transport=mock.Mock(),
        )

    def _make_yh_executable(self):
        (self.app / "Contents" / "MacOS").mkdir(parents=True)
        (self.app / "Contents" / "MacOS" / "yh").write_text("#!/bin/sh\n")

    def test_missing_yh_executable_fails_first(self):
        with self.assertRaises(suite_env.SetupFailed) as ctx:
            suite_env.preflight(self.env, set())
        self.assertIn("no yh executable", str(ctx.exception))

    def test_orca_not_ready_stops_before_git(self):
        self._make_yh_executable()
        with mock.patch.object(suite_env, "orca_status_ready", return_value=False) as orca_mock, \
             mock.patch("subprocess.run") as run_mock:
            with self.assertRaises(suite_env.SetupFailed) as ctx:
                suite_env.preflight(self.env, set())
        orca_mock.assert_called_once()
        run_mock.assert_not_called()
        self.assertIn("orca status", str(ctx.exception))

    def test_old_git_version_fails(self):
        self._make_yh_executable()
        git_result = mock.Mock(returncode=0, stdout="git version 2.30.0\n")
        with mock.patch.object(suite_env, "orca_status_ready", return_value=True), \
             mock.patch.object(suite_env.subprocess, "run", return_value=git_result):
            with self.assertRaises(suite_env.SetupFailed) as ctx:
                suite_env.preflight(self.env, set())
        self.assertIn("git 2.38", str(ctx.exception))

    def test_team_not_found_fails(self):
        self._make_yh_executable()
        (self.configuration_directory / "config.toml").write_text('[linear]\nclient_id = "cid"\n')
        git_result = mock.Mock(returncode=0, stdout="git version 2.40.0\n")
        with mock.patch.object(suite_env, "orca_status_ready", return_value=True), \
             mock.patch.object(suite_env.subprocess, "run", return_value=git_result), \
             mock.patch.object(suite_env.scratch_linear, "keychain_secret", return_value="secret"), \
             mock.patch.object(suite_env.scratch_linear, "find_team", return_value=None):
            with self.assertRaises(suite_env.SetupFailed) as ctx:
                suite_env.preflight(self.env, set())
        self.assertIn("no Linear team", str(ctx.exception))

    def test_operator_credential_only_checked_when_needed(self):
        self._make_yh_executable()
        (self.configuration_directory / "config.toml").write_text('[linear]\nclient_id = "cid"\n')
        git_result = mock.Mock(returncode=0, stdout="git version 2.40.0\n")
        with mock.patch.object(suite_env, "orca_status_ready", return_value=True), \
             mock.patch.object(suite_env.subprocess, "run", return_value=git_result), \
             mock.patch.object(suite_env.scratch_linear, "keychain_secret", return_value="secret") as secret_mock, \
             mock.patch.object(suite_env.scratch_linear, "find_team", return_value={"id": "team-1", "key": "YLH"}), \
             mock.patch.object(suite_env, "_running_yh_processes", return_value=[]), \
             mock.patch.object(suite_env.scratch_linear, "journal_lease_active", return_value=False):
            suite_env.preflight(self.env, {1, 2})
        secret_mock.assert_called_once_with("linear")

    def test_operator_credential_checked_for_scenario_5(self):
        self._make_yh_executable()
        (self.configuration_directory / "config.toml").write_text('[linear]\nclient_id = "cid"\n')
        git_result = mock.Mock(returncode=0, stdout="git version 2.40.0\n")
        with mock.patch.object(suite_env, "orca_status_ready", return_value=True), \
             mock.patch.object(suite_env.subprocess, "run", return_value=git_result), \
             mock.patch.object(
                 suite_env.scratch_linear, "keychain_secret", side_effect=["app-secret", "operator-key"]
             ) as secret_mock, \
             mock.patch.object(suite_env.scratch_linear, "find_team", return_value={"id": "team-1", "key": "YLH"}), \
             mock.patch.object(suite_env.OperatorClient, "viewer_id", return_value="human-1"), \
             mock.patch.object(suite_env.scratch_linear.LinearClient, "graphql", return_value={"viewer": {"id": "app-1"}}), \
             mock.patch.object(suite_env, "_running_yh_processes", return_value=[]), \
             mock.patch.object(suite_env.scratch_linear, "journal_lease_active", return_value=False):
            suite_env.preflight(self.env, {5})
        self.assertEqual(secret_mock.call_count, 2)

    def test_operator_credential_same_viewer_as_app_fails(self):
        self._make_yh_executable()
        (self.configuration_directory / "config.toml").write_text('[linear]\nclient_id = "cid"\n')
        git_result = mock.Mock(returncode=0, stdout="git version 2.40.0\n")
        with mock.patch.object(suite_env, "orca_status_ready", return_value=True), \
             mock.patch.object(suite_env.subprocess, "run", return_value=git_result), \
             mock.patch.object(
                 suite_env.scratch_linear, "keychain_secret", side_effect=["app-secret", "operator-key"]
             ), \
             mock.patch.object(suite_env.scratch_linear, "find_team", return_value={"id": "team-1", "key": "YLH"}), \
             mock.patch.object(suite_env.OperatorClient, "viewer_id", return_value="same-1"), \
             mock.patch.object(
                 suite_env.scratch_linear.LinearClient, "graphql", return_value={"viewer": {"id": "same-1"}}
             ):
            with self.assertRaises(suite_env.SetupFailed) as ctx:
                suite_env.preflight(self.env, {9})
        self.assertIn("the scratch app itself", str(ctx.exception))

    def _preflight_with_lease(self, lease_active):
        self._make_yh_executable()
        (self.configuration_directory / "config.toml").write_text('[linear]\nclient_id = "cid"\n')
        git_result = mock.Mock(returncode=0, stdout="git version 2.40.0\n")
        with mock.patch.object(suite_env, "orca_status_ready", return_value=True), \
             mock.patch.object(suite_env.subprocess, "run", return_value=git_result), \
             mock.patch.object(suite_env.scratch_linear, "keychain_secret", return_value="secret"), \
             mock.patch.object(suite_env.scratch_linear, "find_team", return_value={"id": "team-1", "key": "YLH"}), \
             mock.patch.object(suite_env, "_running_yh_processes", return_value=[]), \
             mock.patch.object(suite_env.scratch_linear, "journal_lease_active", side_effect=lease_active), \
             mock.patch.object(suite_env, "_sleep") as sleep_mock:
            suite_env.preflight(self.env, set())
        return sleep_mock

    def test_a_dead_runs_lease_is_waited_out(self):
        # rehearsal-suite-a's lease is held for two polls, then expires; rehearsal-suite-b's never was.
        states = iter([True, True, False, False])
        sleep_mock = self._preflight_with_lease(lambda *_: next(states))
        self.assertEqual(sleep_mock.call_count, 2)

    def test_a_lease_outliving_the_ttl_fails(self):
        with self.assertRaises(suite_env.SetupFailed) as ctx:
            self._preflight_with_lease(lambda *_: True)
        self.assertIn("still held", str(ctx.exception))


# MARK: - YhRunner


class YhRunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fake_yh = Path(self.tmp.name) / "yh.sh"
        self.fake_yh.write_text("#!/bin/sh\necho ran: \"$@\"\nexit 0\n")
        self.fake_yh.chmod(0o755)
        self.work_directory = Path(self.tmp.name) / "work"
        self.runner = suite_env.YhRunner(self.fake_yh, self.work_directory, act_timeout=10)

    def test_run_numbers_logs_within_a_scenario(self):
        returncode, output, log_path = self.runner.run("scenario-1", "first", ["validate"])
        self.assertEqual(returncode, 0)
        self.assertIn("ran: validate", output)
        self.assertEqual(log_path.name, "01-first.log")
        returncode, output, log_path = self.runner.run("scenario-1", "second", ["validate"])
        self.assertEqual(log_path.name, "02-second.log")

    def test_counters_are_independent_per_scenario(self):
        self.runner.run("scenario-1", "a", ["validate"])
        _, _, log_path = self.runner.run("scenario-2", "a", ["validate"])
        self.assertEqual(log_path.name, "01-a.log")

    def test_run_act_builds_expected_args(self):
        returncode, output, _ = self.runner.run_act(
            "scenario-1", "author", "rehearsal-suite-a", night="2026-08-25"
        )
        self.assertEqual(returncode, 0)
        self.assertIn("author --project rehearsal-suite-a --force --rehearsal --night 2026-08-25", output)

    def test_run_sets_llvm_profile_file_and_cwd_under_work_directory(self):
        import os

        probe = Path(self.tmp.name) / "probe.sh"
        probe.write_text('#!/bin/sh\necho "PROFILE=$LLVM_PROFILE_FILE"\necho "CWD=$(pwd -P)"\nexit 0\n')
        probe.chmod(0o755)
        runner = suite_env.YhRunner(probe, self.work_directory, act_timeout=10)
        returncode, output, _ = runner.run("scenario-1", "probe", [])
        self.assertEqual(returncode, 0)
        self.assertIn(f"PROFILE={self.work_directory / 'profraw' / '%p.profraw'}", output)
        cwd_line = next(line for line in output.splitlines() if line.startswith("CWD="))
        self.assertEqual(os.path.realpath(cwd_line[4:]), os.path.realpath(str(self.work_directory)))

    def test_start_also_sets_llvm_profile_file_and_cwd(self):
        import os

        probe = Path(self.tmp.name) / "probe.sh"
        probe.write_text('#!/bin/sh\necho "PROFILE=$LLVM_PROFILE_FILE"\necho "CWD=$(pwd -P)"\nexit 0\n')
        probe.chmod(0o755)
        runner = suite_env.YhRunner(probe, self.work_directory, act_timeout=10)
        process, log_path, handle = runner.start("scenario-1", "probe", [])
        process.wait(timeout=5)
        handle.close()
        output = log_path.read_text()
        self.assertIn(f"PROFILE={self.work_directory / 'profraw' / '%p.profraw'}", output)
        cwd_line = next(line for line in output.splitlines() if line.startswith("CWD="))
        self.assertEqual(os.path.realpath(cwd_line[4:]), os.path.realpath(str(self.work_directory)))


class TransientBoardFailureTests(unittest.TestCase):
    def test_matches_http_5xx(self):
        self.assertTrue(suite_env.YhRunner.is_transient_board_failure(1, "Linear answered with HTTP 503"))

    def test_matches_could_not_reach(self):
        self.assertTrue(suite_env.YhRunner.is_transient_board_failure(1, "author: could not reach Linear"))

    def test_matches_timed_out(self):
        self.assertTrue(suite_env.YhRunner.is_transient_board_failure(1, "the request timed out"))

    def test_does_not_match_on_success(self):
        self.assertFalse(suite_env.YhRunner.is_transient_board_failure(0, "Linear answered with HTTP 503"))

    def test_does_not_match_unrelated_failure(self):
        self.assertFalse(suite_env.YhRunner.is_transient_board_failure(1, "ProtectedPathRefused"))

    def test_none_returncode_from_timeout_does_not_match(self):
        self.assertFalse(suite_env.YhRunner.is_transient_board_failure(None, "Linear answered with HTTP 503"))


class YhRunnerRetryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work_directory = Path(self.tmp.name) / "work"
        self.counter_file = Path(self.tmp.name) / "count"
        self.counter_file.write_text("0")
        self.fake_yh = Path(self.tmp.name) / "yh.sh"
        # Fails the first call with a transient message, succeeds the second.
        self.fake_yh.write_text(
            "#!/bin/sh\n"
            f'COUNT=$(cat "{self.counter_file}")\n'
            "COUNT=$((COUNT + 1))\n"
            f'echo "$COUNT" > "{self.counter_file}"\n'
            'if [ "$COUNT" = "1" ]; then echo "Linear answered with HTTP 503"; exit 1; fi\n'
            'echo "ok on attempt $COUNT"\n'
            "exit 0\n"
        )
        self.fake_yh.chmod(0o755)
        self.runner = suite_env.YhRunner(self.fake_yh, self.work_directory, act_timeout=10, retry_delay=0)

    def test_retries_on_transient_failure_and_logs_both_attempts(self):
        with mock.patch.object(suite_env, "_sleep") as sleep_mock:
            returncode, output, log_path = self.runner.run("scenario-1", "author", ["author"])
        self.assertEqual(returncode, 0)
        sleep_mock.assert_called_once_with(0)
        self.assertIn("Linear answered with HTTP 503", output)
        self.assertIn("ok on attempt 2", output)
        self.assertIn("retry 1 of 2", log_path.read_text())
        self.assertEqual(self.counter_file.read_text(), "2\n")

    def test_no_retry_when_disabled(self):
        with mock.patch.object(suite_env, "_sleep") as sleep_mock:
            returncode, output, _ = self.runner.run("scenario-1", "author", ["author"], retry=False)
        self.assertEqual(returncode, 1)
        sleep_mock.assert_not_called()
        self.assertEqual(self.counter_file.read_text(), "1\n")

    def test_validate_never_retries(self):
        with mock.patch.object(suite_env, "_sleep") as sleep_mock:
            returncode, _, _ = self.runner.run_validate("scenario-1")
        self.assertEqual(returncode, 1)
        sleep_mock.assert_not_called()

    def test_setup_retries_like_an_act(self):
        with mock.patch.object(suite_env, "_sleep"):
            returncode, _, _ = self.runner.run_setup("scenario-1", ["--init"])
        self.assertEqual(returncode, 0)
        self.assertEqual(self.counter_file.read_text(), "2\n")

    def test_gives_up_after_max_retries(self):
        always_failing = Path(self.tmp.name) / "yh-always-503.sh"
        always_failing.write_text(
            "#!/bin/sh\n"
            f'COUNT=$(cat "{self.counter_file}")\n'
            'echo "$((COUNT + 1))" > "' + str(self.counter_file) + '"\n'
            'echo "Linear answered with HTTP 503"\nexit 1\n'
        )
        always_failing.chmod(0o755)
        runner = suite_env.YhRunner(always_failing, self.work_directory, act_timeout=10, retry_delay=0, max_retries=2)
        with mock.patch.object(suite_env, "_sleep") as sleep_mock:
            returncode, _, log_path = runner.run("scenario-1", "author", ["author"])
        self.assertEqual(returncode, 1)
        self.assertEqual(sleep_mock.call_count, 2)
        self.assertEqual(self.counter_file.read_text(), "3\n")
        self.assertIn("retry 2 of 2", log_path.read_text())

    def test_no_retry_on_non_transient_failure(self):
        fake_yh = Path(self.tmp.name) / "yh-other-failure.sh"
        fake_yh.write_text('#!/bin/sh\necho "ProtectedPathRefused"\nexit 1\n')
        fake_yh.chmod(0o755)
        runner = suite_env.YhRunner(fake_yh, self.work_directory, act_timeout=10, retry_delay=0)
        with mock.patch.object(suite_env, "_sleep") as sleep_mock:
            returncode, output, _ = runner.run("scenario-1", "build", ["build"])
        self.assertEqual(returncode, 1)
        sleep_mock.assert_not_called()

    def test_start_never_retries(self):
        # start() has no retry parameter at all; a failing process is simply what it is.
        self.assertFalse(hasattr(suite_env.YhRunner.start, "retry"))
        process, log_path, handle = self.runner.start("scenario-1", "author", ["author"])
        process.wait(timeout=5)
        handle.close()
        self.assertEqual(self.counter_file.read_text(), "1\n")


if __name__ == "__main__":
    unittest.main()
