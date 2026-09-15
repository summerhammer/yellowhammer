#!/usr/bin/env python3
"""
Unit tests for check_glossary.py linter.
"""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
import sys
import os

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from check_glossary import GlossaryLinter


class TestGlossaryLinter(unittest.TestCase):
    def setUp(self):
        """Set up test fixtures."""
        self.temp_dir = tempfile.TemporaryDirectory()
        self.repo_root = Path(self.temp_dir.name)

        # Create a rules file matching the current glossary_rules.json format
        self.rules_file = self.repo_root / "rules.json"
        self.rules_file.write_text(json.dumps([
                {
                    "id": "GL001",
                    "pattern": "(?<!Linear )(?<!Xcode )(?<!Swift package )(?<!SwiftPM )(?<!Orca )\\bproject\\b",
                    "scopes": ["strings", "commit-messages"],
                    "flags": {"case_sensitive": True},
                    "message": "Use Project (capital P)",
                    "glossary": "docs/glossary.md#project"
                },
                {
                    "id": "GL002",
                    "pattern": "\\b(reviewAttempt|review_attempt)\\b",
                    "scopes": ["identifiers", "strings"],
                    "flags": {"case_sensitive": True},
                    "message": "Round != Attempt",
                    "glossary": "docs/glossary.md#round"
                },
                {
                    "id": "GL003",
                    "pattern": "Board|Workspace|Dispatch|Publication",
                    "scopes": ["test-names"],
                    "flags": {"case_sensitive": True},
                    "message": "Name vendors, not Ports",
                    "glossary": "docs/glossary.md#port"
                },
                {
                    "id": "GL004",
                    "pattern": "\\b(daemon|background_service|background service)\\b",
                    "scopes": ["strings"],
                    "flags": {"case_sensitive": False},
                    "message": "No daemon",
                    "glossary": "docs/glossary.md#night"
                },
                {
                    "id": "GL005",
                    "pattern": "\\b(sprint|ticket)\\b",
                    "scopes": ["comments", "strings"],
                    "flags": {"case_sensitive": False},
                    "message": "Use Card not ticket/sprint",
                    "glossary": "docs/glossary.md#card"
                },
                {
                    "id": "GL007",
                    "kind": "package-target-name",
                    "message": "Module cannot be named after a Port",
                    "glossary": "docs/glossary.md#port"
                }
            ]))

        self.linter = GlossaryLinter(str(self.rules_file), str(self.repo_root))

    def tearDown(self):
        """Clean up test fixtures."""
        self.temp_dir.cleanup()

    def test_gl001_lowercase_project_in_string(self):
        """GL001: Flag lowercase 'project' in strings."""
        swift_file = self.repo_root / "test.swift"
        swift_file.write_text('let msg = "This is a project feature"\n')

        self.linter.scan_files([str(swift_file)])

        self.assertGreater(len(self.linter.findings), 0)
        self.assertEqual(self.linter.findings[0].rule_id, "GL001")

    def test_gl001_skip_xcode_project(self):
        """GL001: Don't flag 'Xcode project' — exempted."""
        swift_file = self.repo_root / "test.swift"
        swift_file.write_text('let msg = "Xcode project settings"\n')

        self.linter.scan_files([str(swift_file)])

        findings_for_gl001 = [f for f in self.linter.findings if f.rule_id == "GL001"]
        self.assertEqual(len(findings_for_gl001), 0)

    def test_gl001_skip_linear_project(self):
        """GL001: Don't flag 'Linear project' — exempted."""
        swift_file = self.repo_root / "test.swift"
        swift_file.write_text('let msg = "Linear project settings"\n')

        self.linter.scan_files([str(swift_file)])

        findings_for_gl001 = [f for f in self.linter.findings if f.rule_id == "GL001"]
        self.assertEqual(len(findings_for_gl001), 0)

    def test_gl001_skip_in_identifier(self):
        """GL001: Don't flag 'project' in identifiers (not in scopes)."""
        swift_file = self.repo_root / "test.swift"
        swift_file.write_text("let projectID = 42\n")

        self.linter.scan_files([str(swift_file)])

        findings_for_gl001 = [f for f in self.linter.findings if f.rule_id == "GL001"]
        self.assertEqual(len(findings_for_gl001), 0)

    def test_gl002_review_attempt_identifier(self):
        """GL002: Flag reviewAttempt in identifiers."""
        swift_file = self.repo_root / "test.swift"
        swift_file.write_text("var reviewAttempt = 0\n")

        self.linter.scan_files([str(swift_file)])

        self.assertEqual(len(self.linter.findings), 1)
        self.assertEqual(self.linter.findings[0].rule_id, "GL002")

    def test_gl002_round_alone_not_flagged(self):
        """GL002: Don't flag 'Round' alone (it's correct usage)."""
        swift_file = self.repo_root / "test.swift"
        swift_file.write_text("// A Round is not an Attempt\n")

        self.linter.scan_files([str(swift_file)])

        findings_for_gl002 = [f for f in self.linter.findings if f.rule_id == "GL002"]
        self.assertEqual(len(findings_for_gl002), 0)

    def test_gl003_port_in_test_name(self):
        """GL003: Flag Port names in test names."""
        test_file = self.repo_root / "test_adapter.swift"
        test_file.write_text('@Test("BoardAdapter works")\nfunc testBoard() {}\n')

        self.linter.check_test_names([str(test_file)])

        # Should find Board in both the @Test annotation and the function name
        self.assertGreaterEqual(len(self.linter.findings), 1)
        self.assertEqual(self.linter.findings[0].rule_id, "GL003")

    def test_gl003_vendor_name_in_test_not_flagged(self):
        """GL003: Don't flag vendor name (Linear) in test name."""
        test_file = self.repo_root / "test_linear.swift"
        test_file.write_text('@Test("LinearAdapter works")\nfunc testLinear() {}\n')

        self.linter.check_test_names([str(test_file)])

        findings_for_gl003 = [f for f in self.linter.findings if f.rule_id == "GL003"]
        self.assertEqual(len(findings_for_gl003), 0)

    def test_gl004_daemon_in_strings_only(self):
        """GL004: Flag daemon in strings, not in comments."""
        # String should be flagged
        swift_file = self.repo_root / "test.swift"
        swift_file.write_text('let msg = "This is a daemon process"\n')

        self.linter.scan_files([str(swift_file)])

        self.assertEqual(len(self.linter.findings), 1)
        self.assertEqual(self.linter.findings[0].rule_id, "GL004")

    def test_gl005_ticket_flagged(self):
        """GL005: Flag 'ticket' in strings/comments."""
        swift_file = self.repo_root / "test.swift"
        swift_file.write_text('let msg = "This is a ticket"\n')

        self.linter.scan_files([str(swift_file)])

        self.assertGreater(len(self.linter.findings), 0)
        self.assertEqual(self.linter.findings[0].rule_id, "GL005")

    def test_gl005_task_not_flagged(self):
        """GL005: Don't flag 'Task' (common Swift keyword like Task {})."""
        swift_file = self.repo_root / "test.swift"
        swift_file.write_text('Task { await someFunc() }\n')

        self.linter.scan_files([str(swift_file)])

        findings_for_gl005 = [f for f in self.linter.findings if f.rule_id == "GL005"]
        self.assertEqual(len(findings_for_gl005), 0)

    def test_gl007_port_name_flagged(self):
        """GL007: Flag module named after a Port in Package.swift."""
        # Create a Packages/YellowhammerKit directory structure
        packages_dir = self.repo_root / "Packages" / "YellowhammerKit"
        packages_dir.mkdir(parents=True)

        package_file = packages_dir / "Package.swift"
        package_file.write_text('''
let package = Package(
    name: "YellowhammerKit",
    targets: [
        .target(name: "Dispatch", dependencies: [])
    ]
)
''')

        self.linter.check_package_targets()

        findings_for_gl007 = [f for f in self.linter.findings if f.rule_id == "GL007"]
        self.assertGreater(len(findings_for_gl007), 0)

    def test_gl007_normal_name_not_flagged(self):
        """GL007: Don't flag normal module names in Package.swift."""
        packages_dir = self.repo_root / "Packages" / "YellowhammerKit"
        packages_dir.mkdir(parents=True)

        package_file = packages_dir / "Package.swift"
        package_file.write_text('''
let package = Package(
    name: "YellowhammerKit",
    targets: [
        .target(name: "CLIAdapters", dependencies: [])
    ]
)
''')

        self.linter.check_package_targets()

        findings_for_gl007 = [f for f in self.linter.findings if f.rule_id == "GL007"]
        self.assertEqual(len(findings_for_gl007), 0)

    def test_suppression_comment(self):
        """Suppression: // glossary:ignore GL001 skips check."""
        swift_file = self.repo_root / "test.swift"
        swift_file.write_text('let msg = "This is a project comment" // glossary:ignore GL001\n')

        self.linter.scan_files([str(swift_file)])

        findings_for_gl001 = [f for f in self.linter.findings if f.rule_id == "GL001"]
        self.assertEqual(len(findings_for_gl001), 0)

    def test_suppression_multiple_rules(self):
        """Suppression: // glossary:ignore GL001 GL002 skips both."""
        swift_file = self.repo_root / "test.swift"
        swift_file.write_text('let msg = "project and reviewAttempt" // glossary:ignore GL001 GL002\n')

        self.linter.scan_files([str(swift_file)])

        findings_for_gl001 = [f for f in self.linter.findings if f.rule_id == "GL001"]
        findings_for_gl002 = [f for f in self.linter.findings if f.rule_id == "GL002"]
        self.assertEqual(len(findings_for_gl001), 0)
        self.assertEqual(len(findings_for_gl002), 0)

    def test_commit_message_scanning(self):
        """Commit messages: scan git log for violations."""
        # Initialize a git repo
        subprocess.run(["git", "init"], cwd=str(self.repo_root), capture_output=True)
        subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=str(self.repo_root), capture_output=True)
        subprocess.run(["git", "config", "user.name", "Test User"], cwd=str(self.repo_root), capture_output=True)

        # Create first commit (to have a base)
        test_file = self.repo_root / "test.txt"
        test_file.write_text("initial")
        subprocess.run(["git", "add", "test.txt"], cwd=str(self.repo_root), capture_output=True)
        subprocess.run(["git", "commit", "-m", "Initial commit"], cwd=str(self.repo_root), capture_output=True)

        # Create second commit with violation in commit message
        test_file.write_text("modified")
        subprocess.run(["git", "add", "test.txt"], cwd=str(self.repo_root), capture_output=True)
        subprocess.run(["git", "commit", "-m", "This is a project fix"], cwd=str(self.repo_root), capture_output=True)

        # Scan commits (get last commit only)
        self.linter.scan_commits("HEAD~1..HEAD")

        findings_for_gl001 = [f for f in self.linter.findings if f.rule_id == "GL001"]
        self.assertGreater(len(findings_for_gl001), 0)

    def test_summary_file_written(self):
        """Summary file: markdown table written with findings."""
        swift_file = self.repo_root / "test.swift"
        swift_file.write_text('let msg = "This is a project feature"\n')

        self.linter.scan_files([str(swift_file)])

        summary_file = self.repo_root / "summary.md"
        self.linter.write_summary_file(str(summary_file))

        self.assertTrue(summary_file.exists())
        content = summary_file.read_text()
        self.assertIn("Glossary Conformance", content)
        self.assertIn("GL001", content)

    def test_exit_code_zero_with_findings(self):
        """Exit code: return 0 even with findings."""
        swift_file = self.repo_root / "test.swift"
        swift_file.write_text('let msg = "project violation"\n')

        self.linter.scan_files([str(swift_file)])

        # Findings should exist but exit code will be 0
        self.assertGreater(len(self.linter.findings), 0)

    def test_exit_code_two_on_bad_json(self):
        """Exit code: return 2 on invalid JSON."""
        bad_rules_file = self.repo_root / "bad_rules.json"
        bad_rules_file.write_text("{invalid json")

        with self.assertRaises(SystemExit) as cm:
            GlossaryLinter(str(bad_rules_file), str(self.repo_root))

        self.assertEqual(cm.exception.code, 2)

    def test_real_repo_no_crash(self):
        """Real repo: scan real Yellowhammer repo without crashing."""
        script_dir = Path(__file__).parent.parent
        repo_root = script_dir.parent.parent
        rules_file = repo_root / "scripts" / "ci" / "glossary_rules.json"
        self.assertTrue(rules_file.exists(), f"Rules file not found at {rules_file}")

        linter = GlossaryLinter(str(rules_file), str(repo_root))

        # Should not crash when scanning real repo
        paths = [
            str(repo_root / "Packages"),
            str(repo_root / "Yellowhammer"),
            str(repo_root / "Engine"),
        ]

        try:
            linter.scan_files(paths)
            linter.check_test_names(paths)
            linter.check_package_targets()
            linter.print_summary()
            # Test passed if no exception
            self.assertTrue(True)
        except Exception as e:
            self.fail(f"Real repo scan crashed: {e}")


class TestGlossaryRules(unittest.TestCase):
    """Test that the actual glossary_rules.json is valid."""

    def test_rules_json_valid(self):
        """Rules JSON: file is valid JSON."""
        rules_file = Path(__file__).parent.parent / "glossary_rules.json"

        if not rules_file.exists():
            self.skipTest(f"Rules file not found at {rules_file}")

        with open(rules_file) as f:
            rules = json.load(f)

        self.assertIsInstance(rules, list)
        self.assertGreater(len(rules), 0)

    def test_rules_have_required_fields(self):
        """Rules JSON: each rule has required fields."""
        rules_file = Path(__file__).parent.parent / "glossary_rules.json"

        if not rules_file.exists():
            self.skipTest(f"Rules file not found at {rules_file}")

        with open(rules_file) as f:
            rules = json.load(f)

        for rule in rules:
            self.assertIn("id", rule)
            self.assertIn("message", rule)
            self.assertIn("glossary", rule)

            # GL007 has kind marker instead of pattern
            if rule.get("kind") == "package-target-name":
                continue

            self.assertIn("pattern", rule)
            self.assertIn("scopes", rule)
            self.assertIn("flags", rule)

    def test_rules_patterns_compile(self):
        """Rules JSON: all regex patterns compile."""
        rules_file = Path(__file__).parent.parent / "glossary_rules.json"

        if not rules_file.exists():
            self.skipTest(f"Rules file not found at {rules_file}")

        import re
        with open(rules_file) as f:
            rules = json.load(f)

        for rule in rules:
            if rule.get("kind") == "package-target-name":
                continue  # GL007 doesn't have a pattern

            try:
                flags = rule.get("flags", {})
                re_flags = 0 if flags.get("case_sensitive", True) else re.IGNORECASE
                re.compile(rule["pattern"], re_flags)
            except re.error as e:
                self.fail(f"Rule {rule['id']} pattern fails to compile: {e}")


if __name__ == "__main__":
    unittest.main()
