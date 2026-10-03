"""Unit tests for the slice-C helpers (scenarios 7, 8, 10, 12): lease-expiry waiting, SIGKILL
detection, the one-shot hold Check's TOML rendering, leftover-process cleanup, worktree ownership,
and the per-Project Journal set helpers."""

import json
import signal
import sqlite3
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import suite_env  # noqa: E402


# MARK: - hold_check_command + TOML literal-string rendering


class HoldCheckCommandTests(unittest.TestCase):
    def test_renders_the_expected_shell(self):
        command = suite_env.hold_check_command("/tmp/W")
        self.assertIn('if [ -e "/tmp/W/HOLD" ]', command)
        self.assertIn('rm -f "/tmp/W/HOLD"', command)
        self.assertIn(': > "/tmp/W/STARTED"', command)
        self.assertIn("exec sleep 3600", command)
        self.assertTrue(command.rstrip().endswith("fi; true"))

    def test_renders_in_project_toml_as_a_literal_string_and_parses_back(self):
        command = suite_env.hold_check_command("/tmp/W")
        text = suite_env.render_project_toml(
            project_id="rehearsal-suite-a", name="A", installation="scratch", linear_project="lp", spec_source="/tmp/spec",
            repos=[{
                "name": "fixture-backend", "path": "/tmp/backend", "role": "backend",
                "check": command, "check_literal": True,
            }],
        )
        # A TOML literal string is single-quoted in the source; the embedded double quotes are
        # never escaped.
        self.assertIn(f"check = '{command}'", text)
        self.assertNotIn('check = "', text)
        data = tomllib.loads(text)
        self.assertEqual(data["repos"][0]["check"], command)

    def test_literal_string_rejects_an_embedded_single_quote(self):
        with self.assertRaises(ValueError):
            suite_env.render_project_toml(
                project_id="p", name="p", installation="scratch", linear_project="lp", spec_source="/tmp/spec",
                repos=[{
                    "name": "r", "path": "/tmp/r", "role": "backend",
                    "check": "it's broken", "check_literal": True,
                }],
            )

    def test_non_literal_check_still_uses_a_basic_string(self):
        text = suite_env.render_project_toml(
            project_id="p", name="p", installation="scratch", linear_project="lp", spec_source="/tmp/spec",
            repos=[{"name": "r", "path": "/tmp/r", "role": "backend", "check": "npm test"}],
        )
        self.assertIn('check = "npm test"', text)


# MARK: - wait_for_file


class WaitForFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_returns_true_once_the_file_appears(self):
        path = Path(self.tmp.name) / "STARTED"
        calls = []

        def fake_sleep(_seconds):
            calls.append(1)
            if len(calls) == 2:
                path.write_text("started\n")

        result = suite_env.wait_for_file(path, timeout=10, poll_interval=0.01, sleep=fake_sleep)
        self.assertTrue(result)

    def test_returns_true_immediately_if_already_present(self):
        path = Path(self.tmp.name) / "STARTED"
        path.write_text("started\n")
        result = suite_env.wait_for_file(path, timeout=10, sleep=mock.Mock())
        self.assertTrue(result)

    def test_returns_false_when_still_running_turns_false(self):
        path = Path(self.tmp.name) / "STARTED"
        result = suite_env.wait_for_file(
            path, timeout=10, poll_interval=0.01, still_running=lambda: False, sleep=mock.Mock()
        )
        self.assertFalse(result)

    def test_returns_false_on_timeout(self):
        path = Path(self.tmp.name) / "STARTED"
        times = iter([0, 0, 100])  # monotonic() calls: start check, loop check, timeout check

        with mock.patch.object(suite_env.time, "monotonic", side_effect=lambda: next(times, 100)):
            result = suite_env.wait_for_file(path, timeout=1, poll_interval=0.01, sleep=mock.Mock())
        self.assertFalse(result)


# MARK: - wait_until_all_expired


class WaitUntilAllExpiredTests(unittest.TestCase):
    def test_returns_once_active_set_is_empty_and_sleeps_the_extra_delay(self):
        responses = [{"2026-01-01T00:00:10Z"}, {"2026-01-01T00:00:10Z"}, set()]

        def get_active():
            return responses.pop(0)

        sleep_calls = []
        clock = iter([0.0, 1.0, 2.0, 3.0, 4.0, 5.0])
        suite_env.wait_until_all_expired(
            get_active, poll_interval=1.0, timeout=100.0, extra_delay=10.0,
            sleep=lambda seconds: sleep_calls.append(seconds),
            monotonic=lambda: next(clock, 5.0),
        )
        self.assertEqual(sleep_calls[-1], 10.0)
        self.assertEqual(sleep_calls.count(1.0), 2)

    def test_never_polls_again_once_already_empty(self):
        def get_active():
            return set()

        sleep_calls = []
        suite_env.wait_until_all_expired(
            get_active, poll_interval=1.0, timeout=100.0, extra_delay=5.0,
            sleep=lambda seconds: sleep_calls.append(seconds), monotonic=lambda: 0.0,
        )
        self.assertEqual(sleep_calls, [5.0])

    def test_calls_on_tick_about_once_a_minute(self):
        active = {"x"}

        def get_active():
            return active

        ticks = []
        clock_values = [0.0, 0.0, 30.0, 61.0, 61.0, 200.0]  # last one exceeds the timeout

        def monotonic():
            return clock_values.pop(0) if clock_values else 500.0

        with self.assertRaises(suite_env.SetupFailed):
            suite_env.wait_until_all_expired(
                get_active, poll_interval=1.0, timeout=100.0, extra_delay=0.0,
                sleep=mock.Mock(), monotonic=monotonic, on_tick=lambda minute: ticks.append(minute),
            )
        self.assertIn(0, ticks)
        self.assertIn(1, ticks)

    def test_raises_setup_failed_on_timeout(self):
        def get_active():
            return {"still-active"}

        clock = iter([0.0, 200.0])
        with self.assertRaises(suite_env.SetupFailed) as ctx:
            suite_env.wait_until_all_expired(
                get_active, poll_interval=1.0, timeout=100.0,
                sleep=mock.Mock(), monotonic=lambda: next(clock, 200.0),
            )
        self.assertIn("still-active", str(ctx.exception))


# MARK: - SIGKILL detection


class IsKilledBySigkillTests(unittest.TestCase):
    def test_negative_signal_number(self):
        self.assertTrue(suite_env.is_killed_by_sigkill(-signal.SIGKILL))

    def test_shell_convention_128_plus_signal(self):
        self.assertTrue(suite_env.is_killed_by_sigkill(128 + signal.SIGKILL))

    def test_zero_is_not_killed(self):
        self.assertFalse(suite_env.is_killed_by_sigkill(0))

    def test_other_signal_is_not_sigkill(self):
        self.assertFalse(suite_env.is_killed_by_sigkill(-signal.SIGTERM))

    def test_none_is_not_killed(self):
        self.assertFalse(suite_env.is_killed_by_sigkill(None))


# MARK: - Leftover process cleanup


class LeftoverProcessTests(unittest.TestCase):
    def test_find_processes_with_exact_command_line(self):
        ps_output = [
            "111 sleep 3600",
            "222 sleep 3600 --extra",
            "333 /bin/sh -c sleep 3600",
        ]
        with mock.patch.object(suite_env, "_running_yh_processes", return_value=ps_output):
            pids = suite_env.find_processes_with_command_line("sleep 3600")
        self.assertEqual(pids, [111])

    def test_find_processes_returns_empty_when_none_match(self):
        with mock.patch.object(suite_env, "_running_yh_processes", return_value=["111 something-else"]):
            pids = suite_env.find_processes_with_command_line("sleep 3600")
        self.assertEqual(pids, [])

    def test_kill_leftover_processes_signals_each_pid(self):
        killed = []
        with mock.patch.object(suite_env.os, "kill", side_effect=lambda pid, sig: killed.append((pid, sig))):
            result = suite_env.kill_leftover_processes([111, 222])
        self.assertEqual(result, [111, 222])
        self.assertEqual(killed, [(111, signal.SIGKILL), (222, signal.SIGKILL)])

    def test_kill_leftover_processes_tolerates_already_gone(self):
        def fake_kill(pid, sig):
            if pid == 111:
                raise ProcessLookupError()

        with mock.patch.object(suite_env.os, "kill", side_effect=fake_kill):
            result = suite_env.kill_leftover_processes([111, 222])
        self.assertEqual(result, [222])


# MARK: - Worktree ownership by git common dir


class WorktreeGitCommonDirTests(unittest.TestCase):
    def test_returns_stdout_on_success(self):
        result = mock.Mock(returncode=0, stdout="/tmp/root/rehearsal-suite-a/repos/fixture-backend/.git\n")
        with mock.patch.object(suite_env.subprocess, "run", return_value=result):
            common_dir = suite_env.worktree_git_common_dir("/tmp/orca/workspaces/fixture-backend/branch")
        self.assertEqual(common_dir, "/tmp/root/rehearsal-suite-a/repos/fixture-backend/.git")

    def test_returns_none_on_failure(self):
        result = mock.Mock(returncode=128, stdout="")
        with mock.patch.object(suite_env.subprocess, "run", return_value=result):
            common_dir = suite_env.worktree_git_common_dir("/not/a/git/checkout")
        self.assertIsNone(common_dir)


# MARK: - created_issue_title


class CreatedIssueTitleTests(unittest.TestCase):
    def test_reads_the_title_of_an_issue_create(self):
        payload = json.dumps({"createIssue": {"_0": {"title": "Fixture Card", "description": "…"}}})
        self.assertEqual(suite_env.created_issue_title(payload), "Fixture Card")

    def test_none_for_other_writes_and_unreadable_payloads(self):
        self.assertIsNone(suite_env.created_issue_title(json.dumps({"updateIssue": {"_0": "id"}})))
        self.assertIsNone(suite_env.created_issue_title(json.dumps({"createIssue": {"_0": {}}})))
        self.assertIsNone(suite_env.created_issue_title("not json"))
        self.assertIsNone(suite_env.created_issue_title(None))


# MARK: - journal_issue_ids / journal_run_ids


class JournalIssueAndRunIdSetsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.db_path = Path(self.tmp.name) / "journal.db"
        connection = sqlite3.connect(str(self.db_path))
        connection.executescript(
            """
            CREATE TABLE night (id INTEGER PRIMARY KEY, night_card_issue_id TEXT);
            CREATE TABLE card (id INTEGER PRIMARY KEY, issue_id TEXT);
            CREATE TABLE feature (id INTEGER PRIMARY KEY, issue_id TEXT);
            CREATE TABLE outbox (id INTEGER PRIMARY KEY, issue_id TEXT, result TEXT);
            CREATE TABLE event (id INTEGER PRIMARY KEY, run_id TEXT);
            INSERT INTO night VALUES (1, 'night-card-1');
            INSERT INTO card VALUES (1, 'card-1');
            INSERT INTO feature VALUES (1, 'feature-1');
            INSERT INTO outbox VALUES (1, 'outbox-issue-1', NULL);
            INSERT INTO outbox VALUES (2, NULL, 'outbox-result-1');
            INSERT INTO event VALUES (1, 'run-a');
            INSERT INTO event VALUES (2, 'run-a');
            INSERT INTO event VALUES (3, NULL);
            """
        )
        connection.commit()
        connection.close()
        self.snapshot = suite_env.JournalSnapshot(self.db_path)
        self.addCleanup(self.snapshot.close)

    def test_journal_issue_ids_collects_every_source(self):
        ids = suite_env.journal_issue_ids(self.snapshot)
        self.assertEqual(
            ids, {"night-card-1", "card-1", "feature-1", "outbox-issue-1", "outbox-result-1"}
        )

    def test_journal_run_ids_ignores_null(self):
        run_ids = suite_env.journal_run_ids(self.snapshot)
        self.assertEqual(run_ids, {"run-a"})


if __name__ == "__main__":
    unittest.main()
