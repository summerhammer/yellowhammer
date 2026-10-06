import json
import sqlite3
import subprocess
import sys
import tempfile
import tomllib
import unittest
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import suite_env  # noqa: E402

#: A fresh Installation token pair (P17.8): `resolve_app_client` reads this through
#: `scratch_linear.keychain_token_pair`, never a plain secret.
FRESH_APP_PAIR = {
    "access_token": "app-token",
    "refresh_token": "app-refresh",
    "expires_at": (datetime.now(timezone.utc) + timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ"),
}


MACHINE_CONFIG = (
    '[board.linear.connections.scratch]\n'
    'credential = "keychain:linear-scratch"\nworkspace = "ws-1"\nyellowhammer_identity = "app-1"\noperator = "user-123"\n'
)

# MARK: - Project TOML rendering


class RenderProjectTomlTests(unittest.TestCase):
    def test_default_keys_round_trip(self):
        text = suite_env.render_project_toml(
            project_id="rehearsal-suite-a",
            name="Rehearsal Suite A",
            installation="scratch", linear_project="11111111-1111-4111-8111-111111111111",
            spec_source="/tmp/spec",
            repos=[
                {"name": "fixture-backend", "path": "/tmp/backend", "role": "backend"},
                {"name": "fixture-web", "path": "/tmp/web", "role": "web"},
            ],
        )
        data = tomllib.loads(text)
        self.assertEqual(data["id"], "rehearsal-suite-a")
        self.assertEqual(data["name"], "Rehearsal Suite A")
        self.assertEqual(data["board"]["linear"]["project"], "11111111-1111-4111-8111-111111111111")
        self.assertEqual(data["board"]["linear"]["connection"], "scratch")
        self.assertNotIn("linear_project", data)
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
            installation="scratch", linear_project="lp",
            spec_source="/tmp/spec",
            repos=[
                {
                    "name": "fixture-backend", "path": "/tmp/backend", "role": "backend",
                    "check": "npm test", "protected_paths": ["migrations/"],
                },
            ],
            limits={"attempts_per_work_card": 1},
            schedule={"build_every_minutes": 5},
            route="claude/opus/high",
            fallbacks=("claude/sonnet/medium", "claude/opus/high"),
        )
        data = tomllib.loads(text)
        self.assertEqual(data["repos"][0]["check"], "npm test")
        self.assertEqual(data["repos"][0]["protected_paths"], ["migrations/"])
        self.assertEqual(data["limits"]["attempts_per_work_card"], 1)
        self.assertEqual(data["limits"]["review_rounds_max"], suite_env.DEFAULT_LIMITS["review_rounds_max"])
        self.assertEqual(data["schedule"]["build_every_minutes"], 5)
        self.assertEqual(data["routing"][0]["fallbacks"], ["claude/sonnet/medium", "claude/opus/high"])

    def test_escapes_quotes_and_backslashes(self):
        text = suite_env.render_project_toml(
            project_id="p",
            name='Name with "quotes" and \\backslash',
            installation="scratch", linear_project="lp",
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


class IsReportedFeatureBranchTests(unittest.TestCase):
    def test_exact_match_is_valid(self):
        self.assertTrue(suite_env.is_reported_feature_branch("yh-feature-1", "yh-feature-1"))

    def test_prefix_rozd_is_valid(self):
        self.assertTrue(suite_env.is_reported_feature_branch("rozd/yh-feature-1", "yh-feature-1"))

    def test_prefix_team_rozd_is_valid(self):
        self.assertTrue(suite_env.is_reported_feature_branch("team/rozd/yh-feature-1", "yh-feature-1"))

    def test_none_reported_is_invalid(self):
        self.assertFalse(suite_env.is_reported_feature_branch(None, "yh-feature-1"))

    def test_empty_reported_is_invalid(self):
        self.assertFalse(suite_env.is_reported_feature_branch("", "yh-feature-1"))

    def test_wrong_suffix_is_invalid(self):
        self.assertFalse(suite_env.is_reported_feature_branch("xfeature-1", "yh-feature-1"))

    def test_wrong_suffix_with_hyphen_is_invalid(self):
        self.assertFalse(suite_env.is_reported_feature_branch("yh-feature-1-2", "yh-feature-1"))


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
            CREATE TABLE feature (id INTEGER PRIMARY KEY, issue_id TEXT, worktree_name TEXT, state TEXT);
            CREATE TABLE feature_repository (
                feature_id INTEGER, repository TEXT, branch TEXT,
                PRIMARY KEY (feature_id, repository)
            );
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
            INSERT INTO feature_repository VALUES (1, 'fixture-backend', 'rozd/yh-rehearsal-suite-a-feature-1');
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
        self.assertEqual(features[0]["worktree_name"], "yh-rehearsal-suite-a-feature-1")

    def test_feature_repositories(self):
        feature_repos = self.snapshot.feature_repositories()
        self.assertEqual(len(feature_repos), 1)
        self.assertEqual(feature_repos[0]["feature_id"], 1)
        self.assertEqual(feature_repos[0]["repository"], "fixture-backend")
        self.assertEqual(feature_repos[0]["branch"], "rozd/yh-rehearsal-suite-a-feature-1")

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
        (Path(tmp.name) / "config").mkdir(parents=True, exist_ok=True)
        (Path(tmp.name) / "config" / "config.toml").write_text(MACHINE_CONFIG)
        worktrees = [
            {"id": "wt-main", "path": str(clone_path), "branch": "main"},
            {"id": "wt-feature", "path": "/tmp/orca/workspaces/fixture-backend/yh-a-f1", "branch": "yh-a-f1"},
        ]
        rebuilt_manifest = dict(manifest)
        reset_result = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.object(suite_env, "orca_worktree_list", return_value=worktrees), \
             mock.patch.object(suite_env, "orca_worktree_rm") as rm_mock, \
             mock.patch.object(suite_env.subprocess, "run", return_value=reset_result) as run_mock, \
             mock.patch.object(suite_env, "build_fixture_tree", return_value=rebuilt_manifest), \
             mock.patch.object(suite_env, "orca_repo_add") as add_mock:
            result = suite_env.reset_project(env, "rehearsal-suite-a")
        rm_mock.assert_called_once_with("wt-feature")
        reset_command = run_mock.call_args.args[0]
        self.assertEqual(reset_command[reset_command.index("--board-connection") + 1], "scratch")
        self.assertLess(reset_command.index("--board-connection"), reset_command.index("reset"))
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
        (Path(tmp.name) / "config").mkdir(parents=True, exist_ok=True)
        (Path(tmp.name) / "config" / "config.toml").write_text(MACHINE_CONFIG)
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
        (config_dir / "config.toml").write_text(MACHINE_CONFIG)
        self.assertEqual(suite_env.read_operator_identity(config_dir, "scratch"), "user-123")

    def test_reads_the_named_installations_operator(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        config_dir = Path(tmp.name)
        (config_dir / "config.toml").write_text(
            MACHINE_CONFIG + '\n[board.linear.connections."my-ws"]\n'
            'credential = "keychain:linear-other"\nworkspace = "ws-2"\nyellowhammer_identity = "app-2"\noperator = "user-456"\n'
        )
        self.assertEqual(suite_env.read_operator_identity(config_dir, "my-ws"), "user-456")
        self.assertEqual(suite_env.read_operator_identity(config_dir, "scratch"), "user-123")
        self.assertIsNone(suite_env.read_operator_identity(config_dir, "unknown"))

    def test_missing_file_returns_none(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.assertIsNone(suite_env.read_operator_identity(Path(tmp.name), "scratch"))

    def test_missing_key_returns_none(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        config_dir = Path(tmp.name)
        (config_dir / "config.toml").write_text(MACHINE_CONFIG.replace('operator = "user-123"\n', ""))
        self.assertIsNone(suite_env.read_operator_identity(config_dir, "scratch"))


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "root"
        self.config_dir = Path(self.tmp.name) / "config"
        (self.config_dir / "projects").mkdir(parents=True)
        self.second = (
            '\n[board.linear.connections."my-ws"]\n'
            'credential = "keychain:linear-other"\nworkspace = "ws-2"\nyellowhammer_identity = "app-2"\n'
        )

    def make_env(self, installation=None):
        return suite_env.make_environment(
            app=Path(self.tmp.name) / "App.app", team="YLH", root=self.root,
            work_directory=Path(self.tmp.name) / "work", configuration_directory=self.config_dir,
            act_timeout=60, transport=mock.Mock(), installation=installation,
        )

    def test_sole_installation_is_resolved_and_stored(self):
        (self.config_dir / "config.toml").write_text(MACHINE_CONFIG)
        env = self.make_env()
        self.assertIsNone(env.installation)
        self.assertEqual(suite_env.resolve_installation(env).name, "scratch")
        self.assertEqual(env.installation, "scratch")

    def test_several_installations_need_a_name(self):
        (self.config_dir / "config.toml").write_text(MACHINE_CONFIG + self.second)
        with self.assertRaises(suite_env.SetupFailed) as ctx:
            suite_env.resolve_installation(self.make_env())
        self.assertIn("--board-connection <name>", str(ctx.exception))
        env = self.make_env("my-ws")
        self.assertEqual(suite_env.resolve_installation(env).credential, "keychain:linear-other")

    def test_ensure_project_passes_the_installation_to_setup_init(self):
        (self.config_dir / "config.toml").write_text(MACHINE_CONFIG + self.second)
        env = self.make_env("my-ws")
        env.yh = mock.Mock()
        env.yh.run_setup.return_value = (0, "", Path("/dev/null"))
        manifest = {"spec_source": "/tmp/spec", "repos": []}
        with mock.patch.object(suite_env, "build_fixture_tree", return_value=manifest), \
             mock.patch.object(suite_env, "default_repo_declarations", return_value=[]):
            suite_env.ensure_project(env, "rehearsal-suite-a")
        args = env.yh.run_setup.call_args.args[1]
        self.assertEqual(args[args.index("--board-connection") + 1], "my-ws")

    def test_scenario_project_file_preserves_installation_and_project(self):
        (self.config_dir / "config.toml").write_text(MACHINE_CONFIG)
        path = suite_env.project_file_path(self.config_dir, "rehearsal-suite-a")
        path.write_text(
            'id = "rehearsal-suite-a"\n\n[board.linear]\nconnection = "my-ws"\nproject = "lp-a"\n'
        )
        env = self.make_env()
        manifest = {"spec_source": "/tmp/spec", "repos": []}
        with mock.patch.object(suite_env, "default_repo_declarations", return_value=[]):
            suite_env.write_scenario_project_file(env, "rehearsal-suite-a", manifest)
        data = tomllib.loads(path.read_text())
        self.assertEqual(data["board"]["linear"], {"connection": "my-ws", "project": "lp-a"})
        self.assertNotIn("linear_project", data)

    def test_rendered_table_precedes_repos(self):
        text = suite_env.render_project_toml(
            project_id="p", name="p", installation="scratch", linear_project="lp", spec_source="/tmp/spec",
            repos=[{"name": "r", "path": "/tmp/r", "role": "backend"}],
        )
        self.assertLess(text.index("[board.linear]"), text.index("[[repos]]"))
        self.assertLess(text.index("spec_source"), text.index("[board.linear]"))


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

    def test_declare_scope_replaces_only_the_fenced_line(self):
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
        client.declare_scope("ISSUE-1", "**Scope:** migrations/0002_fixture.sql")
        new_description = transport.calls[1]["payload"]["variables"]["description"]
        self.assertIn("**Scope:** migrations/0002_fixture.sql", new_description)
        self.assertNotIn("old/path.sql", new_description)
        self.assertEqual(new_description.count("**Scope:** "), 1)
        self.assertIn("Other managed line.", new_description)
        self.assertIn("Some intro text.", new_description)
        self.assertIn("Trailer text.", new_description)

    def test_declare_scope_refuses_when_block_absent(self):
        transport = FakeTransport([
            (200, json.dumps({"data": {"issue": {"description": "no managed block here"}}})),
        ])
        client = suite_env.OperatorClient(transport, "key")
        with self.assertRaises(suite_env.scratch_linear.LinearError):
            client.declare_scope("ISSUE-1", "**Scope:** x")

    def test_declare_scope_adds_the_line_to_a_freshly_authored_block(self):
        # What authoring posts: the fence holds only the Architectural Brief and the Definition of Done.
        description = (
            "<!-- yh:managed:start -->\n\n### Architectural Brief\n\nApproach prose.\n\n"
            "### Definition of Done\n\n- [ ] <!-- yh:clause:c1 --> Covered. (epic/story)\n"
            "  <!-- yh:managed:end -->\n\nUnit of work."
        )
        transport = FakeTransport([
            (200, json.dumps({"data": {"issue": {"description": description}}})),
            (200, json.dumps({"data": {"issueUpdate": {"success": True}}})),
        ])
        client = suite_env.OperatorClient(transport, "key")
        client.declare_scope("ISSUE-1", "`migrations/0002_fixture.sql`")
        new_description = transport.calls[1]["payload"]["variables"]["description"]
        self.assertTrue(new_description.startswith(
            "<!-- yh:managed:start -->\n**Scope:** `migrations/0002_fixture.sql`\n\n### Architectural Brief\n"
        ))
        self.assertIn("- [ ] <!-- yh:clause:c1 --> Covered. (epic/story)", new_description)
        self.assertTrue(new_description.endswith("  <!-- yh:managed:end -->\n\nUnit of work."))


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
        (self.configuration_directory / "config.toml").write_text(MACHINE_CONFIG)
        git_result = mock.Mock(returncode=0, stdout="git version 2.40.0\n")
        with mock.patch.object(suite_env, "orca_status_ready", return_value=True), \
             mock.patch.object(suite_env.subprocess, "run", return_value=git_result), \
             mock.patch.object(suite_env.scratch_linear, "keychain_token_pair", return_value=FRESH_APP_PAIR), \
             mock.patch.object(suite_env.scratch_linear, "find_team", return_value=None):
            with self.assertRaises(suite_env.SetupFailed) as ctx:
                suite_env.preflight(self.env, set())
        self.assertIn("no Linear team", str(ctx.exception))

    def test_operator_credential_only_checked_when_needed(self):
        self._make_yh_executable()
        (self.configuration_directory / "config.toml").write_text(MACHINE_CONFIG)
        git_result = mock.Mock(returncode=0, stdout="git version 2.40.0\n")
        with mock.patch.object(suite_env, "orca_status_ready", return_value=True), \
             mock.patch.object(suite_env.subprocess, "run", return_value=git_result), \
             mock.patch.object(suite_env.scratch_linear, "keychain_token_pair", return_value=FRESH_APP_PAIR), \
             mock.patch.object(suite_env.scratch_linear, "keychain_secret") as secret_mock, \
             mock.patch.object(suite_env.scratch_linear, "find_team", return_value={"id": "team-1", "key": "YLH"}), \
             mock.patch.object(suite_env, "_running_yh_processes", return_value=[]), \
             mock.patch.object(suite_env.scratch_linear, "journal_lease_active", return_value=False):
            suite_env.preflight(self.env, {1, 2})
        secret_mock.assert_not_called()

    def test_operator_credential_checked_for_scenario_5(self):
        self._make_yh_executable()
        (self.configuration_directory / "config.toml").write_text(MACHINE_CONFIG)
        git_result = mock.Mock(returncode=0, stdout="git version 2.40.0\n")
        with mock.patch.object(suite_env, "orca_status_ready", return_value=True), \
             mock.patch.object(suite_env.subprocess, "run", return_value=git_result), \
             mock.patch.object(suite_env.scratch_linear, "keychain_token_pair", return_value=FRESH_APP_PAIR), \
             mock.patch.object(
                 suite_env.scratch_linear, "keychain_secret", side_effect=["operator-key"]
             ) as secret_mock, \
             mock.patch.object(suite_env.scratch_linear, "find_team", return_value={"id": "team-1", "key": "YLH"}), \
             mock.patch.object(suite_env.OperatorClient, "viewer_id", return_value="human-1"), \
             mock.patch.object(suite_env.scratch_linear.LinearClient, "graphql", return_value={"viewer": {"id": "app-1"}}), \
             mock.patch.object(suite_env, "_running_yh_processes", return_value=[]), \
             mock.patch.object(suite_env.scratch_linear, "journal_lease_active", return_value=False):
            suite_env.preflight(self.env, {5})
        self.assertEqual(secret_mock.call_count, 1)

    def test_operator_credential_same_viewer_as_app_fails(self):
        self._make_yh_executable()
        (self.configuration_directory / "config.toml").write_text(MACHINE_CONFIG)
        git_result = mock.Mock(returncode=0, stdout="git version 2.40.0\n")
        with mock.patch.object(suite_env, "orca_status_ready", return_value=True), \
             mock.patch.object(suite_env.subprocess, "run", return_value=git_result), \
             mock.patch.object(suite_env.scratch_linear, "keychain_token_pair", return_value=FRESH_APP_PAIR), \
             mock.patch.object(
                 suite_env.scratch_linear, "keychain_secret", side_effect=["operator-key"]
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
        (self.configuration_directory / "config.toml").write_text(MACHINE_CONFIG)
        git_result = mock.Mock(returncode=0, stdout="git version 2.40.0\n")
        with mock.patch.object(suite_env, "orca_status_ready", return_value=True), \
             mock.patch.object(suite_env.subprocess, "run", return_value=git_result), \
             mock.patch.object(suite_env.scratch_linear, "keychain_token_pair", return_value=FRESH_APP_PAIR), \
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


# MARK: - Teardown


class FakeYhRunner:
    """Stands in for `env.yh` in teardown tests: records `run_project_remove` calls without
    running a process."""

    def __init__(self, result=None):
        self.calls = []
        self._result = result or (0, "ok", Path("/tmp/project-remove.log"))

    def run_project_remove(self, project_id, label=None):
        self.calls.append(project_id)
        return self._result


class FakeAppClient:
    """Stands in for `env.app_client`: records every `graphql` call, and either returns a fixed
    response or raises a fixed error."""

    def __init__(self, response=None, error=None):
        self.calls = []
        self._response = response if response is not None else {"projectDelete": {"success": True}}
        self._error = error

    def graphql(self, query, variables=None):
        self.calls.append((query, variables))
        if self._error:
            raise self._error
        return self._response


def _setups_payload(setups):
    return {"ok": True, "result": {"setups": setups}}


class TeardownProjectTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "root"
        self.config_dir = Path(self.tmp.name) / "config"
        self.env = suite_env.make_environment(
            app=Path(self.tmp.name) / "App.app", team="YLH", root=self.root,
            work_directory=Path(self.tmp.name) / "work", configuration_directory=self.config_dir,
            act_timeout=60, transport=mock.Mock(),
        )
        self.config_dir.mkdir(parents=True, exist_ok=True)
        (self.config_dir / "config.toml").write_text(MACHINE_CONFIG)
        self.env.yh = FakeYhRunner()
        self.app_client = FakeAppClient()
        self.env.app_client = self.app_client

    def _write_project_file(self, project_id, linear_project_id):
        path = suite_env.project_file_path(self.config_dir, project_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            f'id = "{project_id}"\n\n[board.linear]\nconnection = "scratch"\nproject = "{linear_project_id}"\n'
        )

    def _write_fixture_tree(self, project_id):
        project_dir = self.root / project_id
        project_dir.mkdir(parents=True, exist_ok=True)
        (project_dir / "marker").write_text("x")
        return project_dir

    def test_full_teardown_order_and_calls(self):
        self._write_project_file("rehearsal-suite-a", "lp-a")
        project_dir = self._write_fixture_tree("rehearsal-suite-a")
        inside_setup_path = project_dir / "repos" / "fixture-backend"
        setups = [
            {"id": "s1", "path": str(inside_setup_path)},
            {"id": "s2", "path": "/some/unrelated/repo"},
        ]
        reset_result = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.object(suite_env.subprocess, "run", return_value=reset_result) as run_mock, \
             mock.patch.object(suite_env, "orca_json") as orca_json_mock:
            orca_json_mock.side_effect = lambda args, timeout=60: (
                (0, _setups_payload(setups)) if args == ["project", "setups"] else (0, {"ok": True, "result": {}})
            )
            ok, messages = suite_env.teardown_project(self.env, "rehearsal-suite-a")

        self.assertTrue(ok, messages)
        run_mock.assert_called_once()  # scratch_linear.py reset
        self.assertEqual(self.env.yh.calls, ["rehearsal-suite-a"])
        orca_calls = [call.args[0] for call in orca_json_mock.call_args_list]
        self.assertIn(["project", "setups"], orca_calls)
        self.assertIn(["project", "setup-delete", "--setup", "s1"], orca_calls)
        self.assertNotIn(["project", "setup-delete", "--setup", "s2"], orca_calls)
        self.assertEqual(self.app_client.calls, [(suite_env.PROJECT_DELETE_MUTATION, {"id": "lp-a"})])
        self.assertFalse(project_dir.exists())

    def test_setups_outside_root_id_are_never_deleted(self):
        self._write_project_file("rehearsal-suite-a", "lp-a")
        project_dir = self._write_fixture_tree("rehearsal-suite-a")
        setups = [{"id": "outside", "path": "/some/unrelated/repo"}]
        reset_result = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.object(suite_env.subprocess, "run", return_value=reset_result), \
             mock.patch.object(suite_env, "orca_json") as orca_json_mock:
            orca_json_mock.side_effect = lambda args, timeout=60: (
                (0, _setups_payload(setups)) if args == ["project", "setups"] else (0, {"ok": True, "result": {}})
            )
            ok, _ = suite_env.teardown_project(self.env, "rehearsal-suite-a")
        self.assertTrue(ok)
        orca_calls = [call.args[0] for call in orca_json_mock.call_args_list]
        self.assertEqual([c for c in orca_calls if c[:2] == ["project", "setup-delete"]], [])
        self.assertFalse(project_dir.exists())  # unrelated to setups; still removed as this Project's fixture tree

    def test_no_project_file_skips_reset_and_remove_but_still_unregisters_and_deletes_fixtures(self):
        project_dir = self._write_fixture_tree("rehearsal-suite-b")
        setups = [{"id": "s9", "path": str(project_dir / "repos" / "fixture-backend")}]
        with mock.patch.object(suite_env.subprocess, "run") as run_mock, \
             mock.patch.object(suite_env, "orca_json") as orca_json_mock:
            orca_json_mock.side_effect = lambda args, timeout=60: (
                (0, _setups_payload(setups)) if args == ["project", "setups"] else (0, {"ok": True, "result": {}})
            )
            ok, messages = suite_env.teardown_project(self.env, "rehearsal-suite-b")
        self.assertTrue(ok, messages)
        run_mock.assert_not_called()  # scratch_linear reset never runs: no Project file
        self.assertEqual(self.env.yh.calls, [])  # yh project remove never runs
        self.assertEqual(self.app_client.calls, [])  # no Linear project to delete
        orca_calls = [call.args[0] for call in orca_json_mock.call_args_list]
        self.assertIn(["project", "setup-delete", "--setup", "s9"], orca_calls)
        self.assertFalse(project_dir.exists())

    def test_project_delete_not_found_is_tolerated(self):
        self._write_project_file("rehearsal-suite-a", "lp-a")
        self.env.app_client = FakeAppClient(
            error=suite_env.scratch_linear.LinearError(
                "Linear GraphQL error: [{'message': 'Entity not found: Project'}]"
            )
        )
        reset_result = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.object(suite_env.subprocess, "run", return_value=reset_result), \
             mock.patch.object(suite_env, "orca_json", return_value=(0, _setups_payload([]))):
            ok, messages = suite_env.teardown_project(self.env, "rehearsal-suite-a")
        self.assertTrue(ok, messages)
        self.assertTrue(any("already gone" in message for message in messages))

    def test_a_non_not_found_linear_error_is_a_failure(self):
        self._write_project_file("rehearsal-suite-a", "lp-a")
        self.env.app_client = FakeAppClient(
            error=suite_env.scratch_linear.LinearError("Linear GraphQL error: rate limited")
        )
        reset_result = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.object(suite_env.subprocess, "run", return_value=reset_result), \
             mock.patch.object(suite_env, "orca_json", return_value=(0, _setups_payload([]))):
            ok, messages = suite_env.teardown_project(self.env, "rehearsal-suite-a")
        self.assertFalse(ok)
        self.assertTrue(any("FAILED" in message for message in messages))

    def test_a_bare_not_found_message_that_is_not_entity_not_found_is_a_failure(self):
        # scratch_linear's own convention is "Entity not found"; a different "not found" phrasing
        # (e.g. a generic HTTP 404 body) must not be silently tolerated.
        self._write_project_file("rehearsal-suite-a", "lp-a")
        self.env.app_client = FakeAppClient(
            error=suite_env.scratch_linear.LinearError("Linear GraphQL request failed (HTTP 404 not found)")
        )
        reset_result = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.object(suite_env.subprocess, "run", return_value=reset_result), \
             mock.patch.object(suite_env, "orca_json", return_value=(0, _setups_payload([]))):
            ok, messages = suite_env.teardown_project(self.env, "rehearsal-suite-a")
        self.assertFalse(ok)
        self.assertTrue(any("FAILED" in message for message in messages))

    def test_project_delete_returning_success_false_is_a_failure(self):
        self._write_project_file("rehearsal-suite-a", "lp-a")
        self.env.app_client = FakeAppClient(response={"projectDelete": {"success": False}})
        reset_result = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.object(suite_env.subprocess, "run", return_value=reset_result), \
             mock.patch.object(suite_env, "orca_json", return_value=(0, _setups_payload([]))):
            ok, messages = suite_env.teardown_project(self.env, "rehearsal-suite-a")
        self.assertFalse(ok)
        self.assertTrue(any("FAILED" in message and "success=false" in message for message in messages))

    def test_step_1_failure_stops_before_step_2_and_keeps_the_project_file(self):
        self._write_project_file("rehearsal-suite-a", "lp-a")
        project_dir = self._write_fixture_tree("rehearsal-suite-a")
        reset_result = mock.Mock(returncode=2, stdout="", stderr="guard failed")
        with mock.patch.object(suite_env.subprocess, "run", return_value=reset_result), \
             mock.patch.object(suite_env, "orca_json") as orca_json_mock:
            ok, messages = suite_env.teardown_project(self.env, "rehearsal-suite-a")
        self.assertFalse(ok)
        self.assertTrue(any("kept" in message for message in messages))
        self.assertEqual(self.env.yh.calls, [])  # step 2 never ran
        orca_json_mock.assert_not_called()  # steps 3-4 never ran
        self.assertEqual(self.app_client.calls, [])
        self.assertTrue(suite_env.project_file_path(self.config_dir, "rehearsal-suite-a").is_file())
        self.assertTrue(project_dir.exists())  # step 5 never ran

    def test_step_2_failure_stops_before_step_3_and_keeps_the_project_file(self):
        self._write_project_file("rehearsal-suite-a", "lp-a")
        project_dir = self._write_fixture_tree("rehearsal-suite-a")
        reset_result = mock.Mock(returncode=0, stdout="", stderr="")
        self.env.yh = FakeYhRunner(result=(1, "yh project remove failed", Path("/tmp/log")))
        with mock.patch.object(suite_env.subprocess, "run", return_value=reset_result), \
             mock.patch.object(suite_env, "orca_json") as orca_json_mock:
            ok, messages = suite_env.teardown_project(self.env, "rehearsal-suite-a")
        self.assertFalse(ok)
        self.assertTrue(any("kept" in message for message in messages))
        self.assertEqual(self.env.yh.calls, ["rehearsal-suite-a"])  # step 2 ran once
        orca_json_mock.assert_not_called()  # steps 3-4 never ran
        self.assertEqual(self.app_client.calls, [])
        self.assertTrue(suite_env.project_file_path(self.config_dir, "rehearsal-suite-a").is_file())
        self.assertTrue(project_dir.exists())  # step 5 never ran

    def test_dry_run_makes_no_mutating_call_and_no_filesystem_change(self):
        self._write_project_file("rehearsal-suite-a", "lp-a")
        project_dir = self._write_fixture_tree("rehearsal-suite-a")
        inside_setup_path = project_dir / "repos" / "fixture-backend"
        setups = [{"id": "s1", "path": str(inside_setup_path)}]
        with mock.patch.object(suite_env.subprocess, "run") as run_mock, \
             mock.patch.object(suite_env, "orca_json", return_value=(0, _setups_payload(setups))) as orca_json_mock:
            ok, messages = suite_env.teardown_project(self.env, "rehearsal-suite-a", dry_run=True)
        self.assertTrue(ok, messages)
        run_mock.assert_not_called()
        self.assertEqual(self.env.yh.calls, [])
        self.assertEqual(self.app_client.calls, [])
        orca_json_mock.assert_called_once_with(["project", "setups"])  # a read, never setup-delete
        self.assertTrue(project_dir.exists())
        self.assertTrue(suite_env.project_file_path(self.config_dir, "rehearsal-suite-a").is_file())


class TeardownTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "root"
        self.root.mkdir()
        self.env = suite_env.make_environment(
            app=Path(self.tmp.name) / "App.app", team="YLH", root=self.root,
            work_directory=Path(self.tmp.name) / "work", configuration_directory=Path(self.tmp.name) / "config",
            act_timeout=60, transport=mock.Mock(),
        )

    def test_a_failing_project_still_tears_down_the_other_and_overall_fails(self):
        def fake_teardown_project(env, project_id, dry_run=False):
            if project_id == "rehearsal-suite-a":
                return False, ["FAILED: boom"]
            return True, ["ok"]

        with mock.patch.object(suite_env, "teardown_preflight"), \
             mock.patch.object(suite_env, "teardown_project", side_effect=fake_teardown_project) as tp_mock:
            overall_ok, results = suite_env.teardown(self.env)

        self.assertFalse(overall_ok)
        self.assertEqual(tp_mock.call_count, 2)
        self.assertEqual({project_id for project_id, _, _ in results}, set(suite_env.SUITE_PROJECTS))

    def test_preflight_failure_raises_and_teardown_project_is_never_called(self):
        with mock.patch.object(suite_env, "teardown_preflight", side_effect=suite_env.SetupFailed("nope")), \
             mock.patch.object(suite_env, "teardown_project") as tp_mock:
            with self.assertRaises(suite_env.SetupFailed):
                suite_env.teardown(self.env)
        tp_mock.assert_not_called()

    def test_root_is_removed_once_empty_after_a_real_teardown(self):
        with mock.patch.object(suite_env, "teardown_preflight"), \
             mock.patch.object(suite_env, "teardown_project", return_value=(True, [])):
            suite_env.teardown(self.env)
        self.assertFalse(self.root.exists())

    def test_root_is_kept_on_a_dry_run(self):
        with mock.patch.object(suite_env, "teardown_preflight"), \
             mock.patch.object(suite_env, "teardown_project", return_value=(True, [])):
            suite_env.teardown(self.env, dry_run=True)
        self.assertTrue(self.root.exists())


class RmtreeWithinRootTests(unittest.TestCase):
    def test_refuses_a_path_outside_root(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name) / "root"
        root.mkdir()
        outside = Path(tmp.name) / "outside"
        outside.mkdir()
        with self.assertRaises(suite_env.SetupFailed):
            suite_env._rmtree_within_root(outside, root)
        self.assertTrue(outside.exists())

    def test_removes_a_path_inside_root(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name) / "root"
        target = root / "rehearsal-suite-a"
        target.mkdir(parents=True)
        suite_env._rmtree_within_root(target, root)
        self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
