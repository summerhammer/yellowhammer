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


if __name__ == "__main__":
    unittest.main()
