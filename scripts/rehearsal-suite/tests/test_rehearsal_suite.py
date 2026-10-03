import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import rehearsal_suite  # noqa: E402
import scenarios  # noqa: E402
import suite_env  # noqa: E402


class ChecksRecorderTests(unittest.TestCase):
    def test_expect_records_and_continues(self):
        checks = rehearsal_suite.ChecksRecorder(1, "Title")
        with redirect_stdout(io.StringIO()):
            self.assertTrue(checks.expect(True, "ok"))
            self.assertFalse(checks.expect(False, "not ok"))
        self.assertEqual(checks.results, [(True, "ok"), (False, "not ok")])
        self.assertFalse(checks.passed)
        self.assertEqual(checks.failures, ["not ok"])

    def test_require_raises_on_failure(self):
        checks = rehearsal_suite.ChecksRecorder(1, "Title")
        with redirect_stdout(io.StringIO()):
            with self.assertRaises(rehearsal_suite.AbortScenario):
                checks.require(False, "required condition")

    def test_require_does_not_raise_on_success(self):
        checks = rehearsal_suite.ChecksRecorder(1, "Title")
        with redirect_stdout(io.StringIO()):
            checks.require(True, "required condition")
        self.assertTrue(checks.passed)

    def test_prints_pass_fail_lines(self):
        checks = rehearsal_suite.ChecksRecorder(3, "Title")
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            checks.expect(True, "condition one")
            checks.expect(False, "condition two")
        output = buffer.getvalue()
        self.assertIn("PASS [3] condition one", output)
        self.assertIn("FAIL [3] condition two", output)


class RunScenarioTests(unittest.TestCase):
    def test_abort_scenario_is_caught_and_reported_as_failed(self):
        def scenario_func(env, checks):
            checks.require(False, "boom")

        spec = scenarios.ScenarioSpec(99, "Test", False, scenario_func)
        with redirect_stdout(io.StringIO()):
            checks = rehearsal_suite.run_scenario(mock.Mock(), spec)
        self.assertFalse(checks.passed)
        self.assertEqual(checks.failures, ["boom"])

    def test_unexpected_exception_is_a_failure_not_a_crash(self):
        def scenario_func(env, checks):
            raise RuntimeError("kaboom")

        spec = scenarios.ScenarioSpec(99, "Test", False, scenario_func)
        with redirect_stdout(io.StringIO()):
            checks = rehearsal_suite.run_scenario(mock.Mock(), spec)
        self.assertFalse(checks.passed)
        self.assertTrue(any("kaboom" in message for message in checks.failures))

    def test_scenario_that_only_expects_success_passes(self):
        def scenario_func(env, checks):
            checks.expect(True, "fine")

        spec = scenarios.ScenarioSpec(99, "Test", False, scenario_func)
        with redirect_stdout(io.StringIO()):
            checks = rehearsal_suite.run_scenario(mock.Mock(), spec)
        self.assertTrue(checks.passed)


class SummaryTests(unittest.TestCase):
    def test_print_summary_all_passed(self):
        checks = rehearsal_suite.ChecksRecorder(1, "Title")
        with redirect_stdout(io.StringIO()):
            checks.expect(True, "ok")
        with redirect_stdout(io.StringIO()) as buffer:
            ok = rehearsal_suite.print_summary([checks])
        self.assertTrue(ok)
        self.assertIn("PASS [1] Title", buffer.getvalue())

    def test_print_summary_one_failed(self):
        checks = rehearsal_suite.ChecksRecorder(1, "Title")
        with redirect_stdout(io.StringIO()):
            checks.expect(False, "broke")
        with redirect_stdout(io.StringIO()) as buffer:
            ok = rehearsal_suite.print_summary([checks])
        self.assertFalse(ok)
        self.assertIn("FAIL [1] Title", buffer.getvalue())
        self.assertIn("broke", buffer.getvalue())


class ScenarioSelectionTests(unittest.TestCase):
    def test_default_selects_every_scenario(self):
        args = mock.Mock(scenario=None)
        self.assertEqual(rehearsal_suite.selected_scenario_numbers(args), sorted(scenarios.SCENARIOS))

    def test_explicit_subset_deduplicated_and_sorted(self):
        args = mock.Mock(scenario=[2, 1, 2])
        self.assertEqual(rehearsal_suite.selected_scenario_numbers(args), [1, 2])

    def test_unknown_scenario_number_raises(self):
        args = mock.Mock(scenario=[9999])
        with self.assertRaises(suite_env.SetupFailed):
            rehearsal_suite.selected_scenario_numbers(args)


class ListCommandTests(unittest.TestCase):
    def test_lists_every_scenario_with_number_and_title(self):
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            exit_code = rehearsal_suite.list_command(mock.Mock())
        self.assertEqual(exit_code, 0)
        output = buffer.getvalue()
        self.assertIn("1. Idle first Night", output)
        self.assertIn("13. Two conflicting Projects plus one valid Project", output)

    def test_marks_operator_scenarios(self):
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            rehearsal_suite.list_command(mock.Mock())
        output = buffer.getvalue()
        self.assertIn("5. Waiting on You answered before landing, and after landing (banked) "
                       "(needs the Operator credential)", output)
        self.assertIn("1. Idle first Night\n", output)


class RunCommandExitCodeTests(unittest.TestCase):
    def test_preflight_failure_is_exit_code_2_and_runs_nothing(self):
        args = mock.Mock(
            scenario=[1], root=Path("/tmp/nonexistent-root"), configuration_directory=Path("/tmp/nonexistent-config"),
            work_directory=None, app=Path("/tmp/nonexistent-app"), team="YLH", act_timeout=60,
        )
        with mock.patch.object(suite_env, "preflight", side_effect=suite_env.SetupFailed("boom")), \
             mock.patch.object(rehearsal_suite, "run_scenario") as run_mock, \
             redirect_stdout(io.StringIO()):
            exit_code = rehearsal_suite.run_command(args)
        self.assertEqual(exit_code, 2)
        run_mock.assert_not_called()

    def test_all_scenarios_pass_is_exit_code_0(self):
        args = mock.Mock(
            scenario=[1], root=Path("/tmp/root"), configuration_directory=Path("/tmp/config"),
            work_directory=None, app=Path("/tmp/app"), team="YLH", act_timeout=60,
        )
        passing_checks = rehearsal_suite.ChecksRecorder(1, "Idle first Night")
        with redirect_stdout(io.StringIO()):
            passing_checks.expect(True, "ok")
        with mock.patch.object(suite_env, "preflight"), \
             mock.patch.object(suite_env, "ensure_project"), \
             mock.patch.object(rehearsal_suite, "run_scenario", return_value=passing_checks), \
             redirect_stdout(io.StringIO()):
            exit_code = rehearsal_suite.run_command(args)
        self.assertEqual(exit_code, 0)

    def test_a_failed_scenario_is_exit_code_1(self):
        args = mock.Mock(
            scenario=[1], root=Path("/tmp/root"), configuration_directory=Path("/tmp/config"),
            work_directory=None, app=Path("/tmp/app"), team="YLH", act_timeout=60,
        )
        failing_checks = rehearsal_suite.ChecksRecorder(1, "Idle first Night")
        with redirect_stdout(io.StringIO()):
            failing_checks.expect(False, "broke")
        with mock.patch.object(suite_env, "preflight"), \
             mock.patch.object(suite_env, "ensure_project"), \
             mock.patch.object(rehearsal_suite, "run_scenario", return_value=failing_checks), \
             redirect_stdout(io.StringIO()):
            exit_code = rehearsal_suite.run_command(args)
        self.assertEqual(exit_code, 1)

    def test_run_prints_the_teardown_hint_pass_or_fail(self):
        args = mock.Mock(
            scenario=[1], root=Path("/tmp/root"), configuration_directory=Path("/tmp/config"),
            work_directory=None, app=Path("/tmp/app"), team="YLH", act_timeout=60,
        )
        failing_checks = rehearsal_suite.ChecksRecorder(1, "Idle first Night")
        with redirect_stdout(io.StringIO()):
            failing_checks.expect(False, "broke")
        with mock.patch.object(suite_env, "preflight"), \
             mock.patch.object(suite_env, "ensure_project"), \
             mock.patch.object(rehearsal_suite, "run_scenario", return_value=failing_checks), \
             redirect_stdout(io.StringIO()) as buffer:
            rehearsal_suite.run_command(args)
        output = buffer.getvalue()
        self.assertIn("rehearsal_suite.py teardown", output)
        self.assertIn("rehearsal-suite-a", output)
        self.assertIn("--install-jobs", output)


class TeardownCommandTests(unittest.TestCase):
    def _args(self, dry_run=False):
        return mock.Mock(
            app=Path("/tmp/app"), team="YLH", root=Path("/tmp/root"),
            configuration_directory=Path("/tmp/config"), work_directory=None, dry_run=dry_run,
        )

    def test_preflight_failure_is_exit_code_2(self):
        with mock.patch.object(suite_env, "teardown", side_effect=suite_env.SetupFailed("boom")), \
             redirect_stdout(io.StringIO()):
            exit_code = rehearsal_suite.teardown_command(self._args())
        self.assertEqual(exit_code, 2)

    def test_all_clean_is_exit_code_0(self):
        with mock.patch.object(
            suite_env, "teardown", return_value=(True, [("rehearsal-suite-a", True, ["ok"])])
        ), redirect_stdout(io.StringIO()):
            exit_code = rehearsal_suite.teardown_command(self._args())
        self.assertEqual(exit_code, 0)

    def test_a_failed_project_is_exit_code_1(self):
        with mock.patch.object(
            suite_env, "teardown", return_value=(False, [("rehearsal-suite-a", False, ["FAILED: boom"])])
        ), redirect_stdout(io.StringIO()):
            exit_code = rehearsal_suite.teardown_command(self._args())
        self.assertEqual(exit_code, 1)

    def test_dry_run_flag_is_passed_through(self):
        with mock.patch.object(suite_env, "teardown", return_value=(True, [])) as teardown_mock, \
             redirect_stdout(io.StringIO()):
            rehearsal_suite.teardown_command(self._args(dry_run=True))
        self.assertTrue(teardown_mock.call_args.kwargs["dry_run"])


class ParseArgumentsTests(unittest.TestCase):
    def test_run_requires_app_and_team(self):
        with self.assertRaises(SystemExit):
            rehearsal_suite.parse_arguments(["run"])

    def test_run_parses_repeatable_scenario(self):
        args = rehearsal_suite.parse_arguments(
            ["run", "--app", "/tmp/App.app", "--team", "YLH", "--scenario", "1", "--scenario", "2"]
        )
        self.assertEqual(args.scenario, [1, 2])

    def test_list_needs_no_arguments(self):
        args = rehearsal_suite.parse_arguments(["list"])
        self.assertEqual(args.command, "list")

    def test_teardown_requires_app_and_team(self):
        with self.assertRaises(SystemExit):
            rehearsal_suite.parse_arguments(["teardown"])

    def test_teardown_parses_dry_run(self):
        args = rehearsal_suite.parse_arguments(
            ["teardown", "--app", "/tmp/App.app", "--team", "YLH", "--dry-run"]
        )
        self.assertEqual(args.command, "teardown")
        self.assertTrue(args.dry_run)

    def test_teardown_dry_run_defaults_to_false(self):
        args = rehearsal_suite.parse_arguments(["teardown", "--app", "/tmp/App.app", "--team", "YLH"])
        self.assertFalse(args.dry_run)

    def test_installation_flag_is_optional_on_run_and_teardown(self):
        run = rehearsal_suite.parse_arguments(["run", "--app", "/tmp/App.app", "--team", "YLH"])
        self.assertIsNone(run.installation)
        run = rehearsal_suite.parse_arguments(
            ["run", "--app", "/tmp/App.app", "--team", "YLH", "--installation", "my-ws"]
        )
        self.assertEqual(run.installation, "my-ws")
        teardown = rehearsal_suite.parse_arguments(
            ["teardown", "--app", "/tmp/App.app", "--team", "YLH", "--installation", "my-ws"]
        )
        self.assertEqual(teardown.installation, "my-ws")


if __name__ == "__main__":
    unittest.main()
