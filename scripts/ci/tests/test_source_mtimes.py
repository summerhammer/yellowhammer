#!/usr/bin/env python3
"""
Unit tests for source_mtimes.py
"""

import importlib.util
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


if __name__ == "__main__":
    unittest.main()
