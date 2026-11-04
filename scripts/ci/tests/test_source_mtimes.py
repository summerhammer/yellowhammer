#!/usr/bin/env python3
"""
Unit tests for source_mtimes.py
"""

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


script_path = Path(__file__).parent.parent / "source_mtimes.py"
spec = importlib.util.spec_from_file_location("source_mtimes", script_path)
source_mtimes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source_mtimes)

OLD = 1_700_000_000_123_456_789


class TestSourceMtimes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.manifest = self.root / ".build" / "source-mtimes.json"
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        for name in ("Unchanged.swift", "Edited.swift"):
            (self.root / name).write_text(f"// {name}\n")
            os.utime(self.root / name, ns=(OLD, OLD))
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)

    def tearDown(self):
        self.tmp.cleanup()

    def checkout(self):
        """Simulate a fresh checkout: every file stamped with the current time."""
        for name in ("Unchanged.swift", "Edited.swift"):
            os.utime(self.root / name)

    def test_unchanged_file_gets_its_recorded_mtime_back(self):
        source_mtimes.record(self.root, self.manifest)
        self.checkout()
        source_mtimes.restore(self.root, self.manifest)
        self.assertEqual((self.root / "Unchanged.swift").stat().st_mtime_ns, OLD)

    def test_edited_file_keeps_the_checkout_time(self):
        source_mtimes.record(self.root, self.manifest)
        (self.root / "Edited.swift").write_text("// edited\n")
        subprocess.run(["git", "add", "Edited.swift"], cwd=self.root, check=True)
        self.checkout()
        source_mtimes.restore(self.root, self.manifest)
        self.assertNotEqual((self.root / "Edited.swift").stat().st_mtime_ns, OLD)
        self.assertEqual((self.root / "Unchanged.swift").stat().st_mtime_ns, OLD)

    def test_new_file_keeps_the_checkout_time(self):
        source_mtimes.record(self.root, self.manifest)
        (self.root / "New.swift").write_text("// new\n")
        subprocess.run(["git", "add", "New.swift"], cwd=self.root, check=True)
        before = (self.root / "New.swift").stat().st_mtime_ns
        source_mtimes.restore(self.root, self.manifest)
        self.assertEqual((self.root / "New.swift").stat().st_mtime_ns, before)

    def test_missing_manifest_is_not_an_error(self):
        self.assertEqual(source_mtimes.restore(self.root, self.manifest), 0)

    def test_tracked_file_missing_from_the_working_tree_is_not_an_error(self):
        source_mtimes.record(self.root, self.manifest)
        self.checkout()
        (self.root / "Edited.swift").unlink()

        self.assertEqual(source_mtimes.restore(self.root, self.manifest), 0)

        self.assertFalse((self.root / "Edited.swift").exists())
        self.assertEqual((self.root / "Unchanged.swift").stat().st_mtime_ns, OLD)

    def test_restore_reports_a_missing_tracked_file_in_the_summary(self):
        source_mtimes.record(self.root, self.manifest)
        (self.root / "Edited.swift").unlink()

        with contextlib.redirect_stdout(io.StringIO()) as output:
            source_mtimes.restore(self.root, self.manifest)

        self.assertIn("Restored 1 source mtimes", output.getvalue())
        self.assertIn("1 tracked files are missing", output.getvalue())

    def test_record_excludes_a_tracked_symlink_to_an_external_file(self):
        with tempfile.TemporaryDirectory() as external:
            target = Path(external) / "SKILL.md"
            target.write_text("external skill\n")
            link = self.root / "skill"
            link.symlink_to(target)
            subprocess.run(["git", "add", "skill"], cwd=self.root, check=True)

            source_mtimes.record(self.root, self.manifest)

            self.assertNotIn("skill", json.loads(self.manifest.read_text()))

    def test_restore_does_not_touch_external_target_in_a_legacy_manifest(self):
        with tempfile.TemporaryDirectory() as external:
            target = Path(external) / "SKILL.md"
            target.write_text("external skill\n")
            link = self.root / "skill"
            link.symlink_to(target)
            subprocess.run(["git", "add", "skill"], cwd=self.root, check=True)
            blob = subprocess.run(
                ["git", "rev-parse", ":skill"], cwd=self.root,
                check=True, capture_output=True, text=True,
            ).stdout.strip()
            self.manifest.parent.mkdir()
            self.manifest.write_text(json.dumps({"skill": [blob, OLD]}))
            before = target.stat().st_mtime_ns

            source_mtimes.restore(self.root, self.manifest)

            self.assertEqual(target.stat().st_mtime_ns, before)

    def test_dangling_tracked_symlink_is_ignored(self):
        (self.root / "skill").symlink_to(self.root / "missing")
        subprocess.run(["git", "add", "skill"], cwd=self.root, check=True)
        source_mtimes.record(self.root, self.manifest)
        self.assertNotIn("skill", json.loads(self.manifest.read_text()))
        self.assertEqual(source_mtimes.restore(self.root, self.manifest), 0)

    def test_repo_root_roundtrip_with_nested_source_and_custom_manifest(self):
        source = self.root / "Packages" / "Kit" / "Sources" / "Nested.swift"
        source.parent.mkdir(parents=True)
        source.write_text("// nested\n")
        os.utime(source, ns=(OLD, OLD))
        subprocess.run(["git", "add", "Packages"], cwd=self.root, check=True)
        manifest = self.root / "build" / "DerivedData" / "source-mtimes.json"

        self.assertEqual(source_mtimes.main([
            "record", "--root", str(self.root), "--manifest", str(manifest),
        ]), 0)
        os.utime(source)
        self.assertNotEqual(source.stat().st_mtime_ns, OLD)
        self.assertEqual(source_mtimes.main([
            "restore", "--root", str(self.root), "--manifest", str(manifest),
        ]), 0)

        self.assertEqual(source.stat().st_mtime_ns, OLD)
        self.assertIn("Packages/Kit/Sources/Nested.swift", json.loads(manifest.read_text()))


if __name__ == "__main__":
    unittest.main()
