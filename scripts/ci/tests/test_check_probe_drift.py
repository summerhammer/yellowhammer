#!/usr/bin/env python3
"""
Unit tests for check_probe_drift.py (P7.5).
"""

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# Load the check_probe_drift module
script_path = Path(__file__).parent.parent / "check_probe_drift.py"
spec = importlib.util.spec_from_file_location("check_probe_drift", script_path)
check_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_module)


SAMPLE_CLEAN_OUTPUT = """cli: claude
cli version: 2.1.274
adapter version: 1
unattended dispatch: passed
result file on clean exit: passed
process containment: passed
session resumption: passed
verdict: passed
offered as a route target
"""

SAMPLE_OUTPUT_FORMAT_DRIFT_OUTPUT = """cli: claude
cli version: 2.2.0
adapter version: 1
unattended dispatch: passed
result file on clean exit: failed
process containment: passed
session resumption: passed
verdict: failed
reason: result schema validation failed: missing field summary
drift since the previous probe (2.1.274/1 -> 2.2.0/1): output format (result file on clean exit)
excluded from routing: result schema validation failed: missing field summary
"""

SAMPLE_ARGV_DRIFT_OUTPUT = """cli: codex
cli version: 0.160.0
adapter version: 1
unattended dispatch: failed
result file on clean exit: not_run
process containment: not_run
session resumption: not_run
verdict: failed
reason: interactive prompt required: auth login
drift since the previous probe (0.154.0/1 -> 0.160.0/1): argv (unattended dispatch)
excluded from routing: interactive prompt required: auth login
"""

SAMPLE_MULTI_DRIFT_OUTPUT = """cli: codex
cli version: 0.170.0
adapter version: 1
unattended dispatch: failed
result file on clean exit: failed
process containment: failed
session resumption: failed
verdict: failed
drift since the previous probe (0.154.0/1 -> 0.170.0/1): argv (unattended dispatch), output format (result file on clean exit), process containment, session handling (session resumption)
excluded from routing: multiple probe failures
"""

SAMPLE_CONTAINMENT_FAILURE_NO_DRIFT = """cli: claude
cli version: 2.1.274
adapter version: 1
unattended dispatch: passed
result file on clean exit: passed
process containment: failed
session resumption: passed
verdict: failed
reason: sigkill: process group survivors (leader 51717, group 51717, pids 51720)
excluded from routing: sigkill: process group survivors (leader 51717, group 51717, pids 51720)
"""

# What the hosted runner printed for every run before #199 was fixed, and still reported green.
SAMPLE_NO_YH_OUTPUT = "error: no executable product named 'yh'\n"

SAMPLE_CLI_NOT_INSTALLED_OUTPUT = "Error: `claude` is not installed: no executable on PATH\n"


class TestParseProbeOutput(unittest.TestCase):
    """Tests for parsing yh probe output."""

    def test_parse_clean_output(self):
        info = check_module.parse_probe_output(SAMPLE_CLEAN_OUTPUT, exit_code=0)
        self.assertEqual(info.cli, "claude")
        self.assertEqual(info.cli_version, "2.1.274")
        self.assertEqual(info.adapter_version, "1")
        self.assertEqual(info.unattended_dispatch, "passed")
        self.assertEqual(info.result_file, "passed")
        self.assertEqual(info.process_containment, "passed")
        self.assertEqual(info.session_resumption, "passed")
        self.assertEqual(info.verdict, "passed")
        self.assertIsNone(info.reason)
        self.assertIsNone(info.drift_message)
        self.assertEqual(info.regressions, [])
        self.assertEqual(info.eligibility, "offered")
        self.assertTrue(info.completed)

    def test_output_without_a_verdict_is_not_completed(self):
        for output, exit_code in [(SAMPLE_NO_YH_OUTPUT, 1), (SAMPLE_CLI_NOT_INSTALLED_OUTPUT, 64), ("", 0)]:
            with self.subTest(output=output, exit_code=exit_code):
                info = check_module.parse_probe_output(output, exit_code=exit_code)
                self.assertFalse(info.completed)

    def test_parse_output_format_drift(self):
        info = check_module.parse_probe_output(SAMPLE_OUTPUT_FORMAT_DRIFT_OUTPUT, exit_code=1)
        self.assertEqual(info.cli, "claude")
        self.assertEqual(info.cli_version, "2.2.0")
        self.assertEqual(info.result_file, "failed")
        self.assertEqual(info.verdict, "failed")
        self.assertIsNotNone(info.drift_message)
        self.assertIn("output format (result file on clean exit)", info.regressions)
        self.assertIn("excluded from routing", info.eligibility)

    def test_parse_argv_drift(self):
        info = check_module.parse_probe_output(SAMPLE_ARGV_DRIFT_OUTPUT, exit_code=1)
        self.assertEqual(info.cli, "codex")
        self.assertEqual(info.cli_version, "0.160.0")
        self.assertEqual(info.unattended_dispatch, "failed")
        self.assertEqual(info.verdict, "failed")
        self.assertIsNotNone(info.drift_message)
        self.assertIn("argv (unattended dispatch)", info.regressions)

    def test_parse_multi_drift(self):
        info = check_module.parse_probe_output(SAMPLE_MULTI_DRIFT_OUTPUT, exit_code=1)
        self.assertEqual(info.cli, "codex")
        self.assertIsNotNone(info.drift_message)
        self.assertEqual(len(info.regressions), 4)

    def test_containment_failure_without_drift(self):
        info = check_module.parse_probe_output(SAMPLE_CONTAINMENT_FAILURE_NO_DRIFT, exit_code=1)
        self.assertEqual(info.cli, "claude")
        self.assertEqual(info.process_containment, "failed")
        self.assertEqual(info.verdict, "failed")
        self.assertIsNone(info.drift_message)
        self.assertEqual(info.regressions, [])


class TestSummaryGeneration(unittest.TestCase):
    """Tests for Markdown summary table formatting."""

    def test_summary_with_clean_and_drift(self):
        clean = check_module.parse_probe_output(SAMPLE_CLEAN_OUTPUT, exit_code=0)
        drift = check_module.parse_probe_output(SAMPLE_OUTPUT_FORMAT_DRIFT_OUTPUT, exit_code=1)

        summary = check_module.generate_markdown_summary([clean, drift])
        self.assertIn("## Agent CLI Probe Drift Report", summary)
        self.assertIn("| `claude` | `2.1.274` | `1` |", summary)
        self.assertIn("| `claude` | `2.2.0` | `1` |", summary)
        self.assertIn("**DRIFT:** output format (result file on clean exit)", summary)
        self.assertIn("Probe Drift Detected", summary)

    def test_summary_all_healthy(self):
        clean1 = check_module.parse_probe_output(SAMPLE_CLEAN_OUTPUT, exit_code=0)
        summary = check_module.generate_markdown_summary([clean1])
        self.assertIn("All Probes Healthy", summary)

    def test_summary_marks_a_probe_that_did_not_run(self):
        clean = check_module.parse_probe_output(SAMPLE_CLEAN_OUTPUT, exit_code=0)
        not_run = check_module.parse_probe_output(SAMPLE_NO_YH_OUTPUT, exit_code=1)._replace(cli="codex")
        summary = check_module.generate_markdown_summary([clean, not_run])
        self.assertIn("| `codex` | | | | | | | **DID NOT RUN** | — |", summary)
        self.assertIn("Probe Did Not Run:** `codex`", summary)
        self.assertNotIn("All Probes Healthy", summary)


class TestMainExecution(unittest.TestCase):
    """Tests for main() CLI entrypoint."""

    def test_main_success_when_no_drift(self):
        with patch.object(check_module, "run_probe_command", return_value=(0, SAMPLE_CLEAN_OUTPUT)):
            with patch.object(sys, "argv", ["check_probe_drift.py", "--clis", "claude"]):
                code = check_module.main()
                self.assertEqual(code, 0)

    def test_main_fails_on_output_format_drift(self):
        with patch.object(check_module, "run_probe_command", return_value=(1, SAMPLE_OUTPUT_FORMAT_DRIFT_OUTPUT)):
            with patch.object(sys, "argv", ["check_probe_drift.py", "--clis", "claude"]):
                code = check_module.main()
                self.assertEqual(code, 1)

    def test_main_fails_when_yh_is_missing(self):
        # The regression in #199: `swift run ... yh` failed, no probe ran, and the check exited 0.
        with patch.object(check_module, "run_probe_command", return_value=(1, SAMPLE_NO_YH_OUTPUT)):
            with patch.object(sys, "argv", ["check_probe_drift.py", "--clis", "claude,codex"]):
                self.assertEqual(check_module.main(), 1)

    def test_main_fails_when_a_probe_did_not_run_even_without_fail_on_error(self):
        with patch.object(check_module, "run_probe_command", return_value=(64, SAMPLE_CLI_NOT_INSTALLED_OUTPUT)):
            with patch.object(sys, "argv", ["check_probe_drift.py", "--clis", "claude", "--no-fail-on-error"]):
                self.assertEqual(check_module.main(), 1)

    def test_main_fails_when_output_has_no_verdict_despite_exit_zero(self):
        with patch.object(check_module, "run_probe_command", return_value=(0, "")):
            with patch.object(sys, "argv", ["check_probe_drift.py", "--clis", "claude"]):
                self.assertEqual(check_module.main(), 1)

    def test_main_fails_on_failed_verdict_without_drift_by_default(self):
        with patch.object(check_module, "run_probe_command", return_value=(1, SAMPLE_CONTAINMENT_FAILURE_NO_DRIFT)):
            with patch.object(sys, "argv", ["check_probe_drift.py", "--clis", "claude"]):
                self.assertEqual(check_module.main(), 1)

    def test_main_passes_failed_verdict_without_drift_when_opted_out(self):
        with patch.object(check_module, "run_probe_command", return_value=(1, SAMPLE_CONTAINMENT_FAILURE_NO_DRIFT)):
            with patch.object(sys, "argv", ["check_probe_drift.py", "--clis", "claude", "--no-fail-on-error"]):
                self.assertEqual(check_module.main(), 0)

    def test_main_passes_drift_when_opted_out(self):
        with patch.object(check_module, "run_probe_command", return_value=(1, SAMPLE_OUTPUT_FORMAT_DRIFT_OUTPUT)):
            argv = ["check_probe_drift.py", "--clis", "claude", "--no-fail-on-drift", "--no-fail-on-error"]
            with patch.object(sys, "argv", argv):
                self.assertEqual(check_module.main(), 0)

    def test_main_fails_on_empty_cli_list(self):
        with patch.object(sys, "argv", ["check_probe_drift.py", "--clis", " , "]):
            self.assertEqual(check_module.main(), 1)

    def test_main_summary_file_written(self):
        with tempfile.NamedTemporaryFile(mode="w+", delete=False) as tf:
            summary_path = tf.name

        try:
            with patch.object(check_module, "run_probe_command", return_value=(0, SAMPLE_CLEAN_OUTPUT)):
                with patch.object(sys, "argv", ["check_probe_drift.py", "--clis", "claude", "--summary-file", summary_path]):
                    code = check_module.main()
                    self.assertEqual(code, 0)

            with open(summary_path, "r", encoding="utf-8") as f:
                content = f.read()
            self.assertIn("## Agent CLI Probe Drift Report", content)
        finally:
            if os.path.exists(summary_path):
                os.remove(summary_path)


class TestRunProbeCommand(unittest.TestCase):
    """Tests for resolving and running `yh`."""

    def test_missing_default_engine_bin_reports_the_build_command(self):
        with tempfile.TemporaryDirectory() as repo_root:
            exit_code, output = check_module.run_probe_command("claude", repo_root=Path(repo_root))
        self.assertEqual(exit_code, 1)
        self.assertIn(check_module.DEFAULT_ENGINE_BIN, output)
        self.assertIn("xcodebuild", output)
        self.assertFalse(check_module.parse_probe_output(output, exit_code).completed)

    def test_runs_the_given_engine_bin(self):
        with tempfile.TemporaryDirectory() as directory:
            stub = Path(directory) / "yh"
            stub.write_text("#!/bin/sh\necho \"cli: $2\"\necho 'verdict: passed'\n")
            stub.chmod(0o755)
            exit_code, output = check_module.run_probe_command("claude", engine_bin=str(stub))
        self.assertEqual(exit_code, 0)
        info = check_module.parse_probe_output(output, exit_code)
        self.assertEqual(info.cli, "claude")
        self.assertTrue(info.completed)

    def test_timeout_is_reported_as_not_run(self):
        with tempfile.TemporaryDirectory() as directory:
            stub = Path(directory) / "yh"
            stub.write_text("#!/bin/sh\nsleep 5\n")
            stub.chmod(0o755)
            exit_code, output = check_module.run_probe_command("claude", engine_bin=str(stub), timeout=1)
        self.assertEqual(exit_code, 1)
        self.assertIn("timed out after 1s", output)
        self.assertFalse(check_module.parse_probe_output(output, exit_code).completed)


if __name__ == "__main__":
    unittest.main()
