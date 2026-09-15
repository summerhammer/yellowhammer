#!/usr/bin/env python3
"""
Unit tests for check_spec_line.py
"""

import importlib.util
import sys
import unittest
from pathlib import Path


# Load the check_spec_line module
script_path = Path(__file__).parent.parent / "check_spec_line.py"
spec = importlib.util.spec_from_file_location("check_spec_line", script_path)
check_spec_line_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_spec_line_module)


class TestCheckSpecLine(unittest.TestCase):
    """Tests for spec line validation."""

    def test_valid_line(self):
        """Test a single valid spec line."""
        body = "Spec: project-setup/initial-schema @ a1b2c3d"
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertTrue(is_valid)
        self.assertEqual(len(matched), 1)
        self.assertEqual(len(errors), 0)

    def test_multiple_valid_lines(self):
        """Test multiple valid spec lines."""
        body = """## Summary
Some summary here.

Spec: project-setup/initial-schema @ a1b2c3d
Spec: engine/run-action @ deadbeef123

More description."""
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertTrue(is_valid)
        self.assertEqual(len(matched), 2)
        self.assertEqual(len(errors), 0)

    def test_valid_exempt(self):
        """Test a valid exempt line."""
        body = "Spec-Exempt: DevOps infrastructure setup"
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertTrue(is_valid)
        self.assertEqual(len(matched), 1)
        self.assertEqual(matched[0][2], "exempt")
        self.assertEqual(len(errors), 0)

    def test_empty_body(self):
        """Test empty PR body."""
        body = ""
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertFalse(is_valid)
        self.assertEqual(len(matched), 0)

    def test_template_placeholder_only(self):
        """Test body with only the template placeholder."""
        body = "Spec: <epic>/<story> @ <spec commit sha>"
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertFalse(is_valid)
        self.assertEqual(len(matched), 0)

    def test_uppercase_slug(self):
        """Test that uppercase slugs are invalid."""
        body = "Spec: Project-Setup/Initial-Schema @ a1b2c3d"
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertFalse(is_valid)
        self.assertEqual(len(errors), 1)

    def test_missing_sha(self):
        """Test spec line missing SHA."""
        body = "Spec: project-setup/initial-schema @"
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertFalse(is_valid)
        self.assertEqual(len(errors), 1)

    def test_short_sha(self):
        """Test SHA that is too short (6 chars)."""
        body = "Spec: project-setup/initial-schema @ a1b2c3"
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertFalse(is_valid)
        self.assertEqual(len(errors), 1)

    def test_non_hex_sha(self):
        """Test SHA with non-hex characters."""
        body = "Spec: project-setup/initial-schema @ g1b2c3d123456"
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertFalse(is_valid)
        self.assertEqual(len(errors), 1)

    def test_three_path_segments(self):
        """Test that three path segments are invalid."""
        body = "Spec: project/setup/initial-schema @ a1b2c3d"
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertFalse(is_valid)
        self.assertEqual(len(errors), 1)

    def test_line_inside_html_comment(self):
        """Test that lines inside HTML comments are ignored."""
        body = """## Summary

<!-- This is a comment
Spec: project-setup/initial-schema @ a1b2c3d
End comment -->

Spec: real-epic/real-story @ deadbeef123"""
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertTrue(is_valid)
        # Should only match the one outside the comment
        self.assertEqual(len(matched), 1)
        self.assertIn("real-epic", matched[0][1])

    def test_line_inside_code_fence(self):
        """Test that lines inside code fences are ignored."""
        body = """## Summary

```
Spec: project-setup/initial-schema @ a1b2c3d
```

Spec: real-epic/real-story @ deadbeef123"""
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertTrue(is_valid)
        # Should only match the one outside the fence
        self.assertEqual(len(matched), 1)
        self.assertIn("real-epic", matched[0][1])

    def test_crlf_line_endings(self):
        """Test handling of CRLF line endings."""
        body = "Spec: project-setup/initial-schema @ a1b2c3d\r\nMore text here\r\n"
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertTrue(is_valid)
        self.assertEqual(len(matched), 1)

    def test_empty_exemption_reason(self):
        """Test that empty exemption reason is invalid."""
        body = "Spec-Exempt:"
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertFalse(is_valid)
        self.assertEqual(len(errors), 1)

    def test_exemption_with_placeholder_reason(self):
        """Test that exemption with placeholder reason is invalid."""
        body = "Spec-Exempt: <reason>"
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertFalse(is_valid)

    def test_mixed_valid_and_invalid(self):
        """Test mixed valid and invalid lines."""
        body = """Spec: project-setup/initial-schema @ a1b2c3d
Spec: bad-epic-bad/story @
Spec-Exempt: Some reason"""
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        # Should fail due to malformed line
        self.assertFalse(is_valid)

    def test_whitespace_tolerance(self):
        """Test that leading/trailing whitespace is tolerated."""
        body = "  Spec: project-setup/initial-schema @ a1b2c3d  "
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertTrue(is_valid)
        self.assertEqual(len(matched), 1)

    def test_long_sha(self):
        """Test with maximum length SHA (40 chars)."""
        body = "Spec: project-setup/initial-schema @ " + "a" * 40
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertTrue(is_valid)

    def test_minimum_sha(self):
        """Test with minimum length SHA (7 chars)."""
        body = "Spec: project-setup/initial-schema @ a1b2c3d"
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertTrue(is_valid)

    def test_hyphenated_slugs(self):
        """Test that hyphenated slugs work."""
        body = "Spec: my-epic-name/my-story-name @ deadbeef123"
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertTrue(is_valid)

    def test_numeric_slugs(self):
        """Test that numeric characters in slugs work."""
        body = "Spec: project2/story3 @ deadbeef123"
        is_valid, matched, errors = check_spec_line_module.check_spec_line(body)
        self.assertTrue(is_valid)


if __name__ == "__main__":
    unittest.main()
