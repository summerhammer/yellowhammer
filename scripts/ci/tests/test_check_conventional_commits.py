#!/usr/bin/env python3
"""Unit tests for scripts/ci/check_conventional_commits.py."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from check_conventional_commits import check_header, commit_headers  # noqa: E402

SCRIPT_PATH = Path(__file__).resolve().parent.parent / "check_conventional_commits.py"


def run_git(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )


def commit(repo, message):
    run_git(
        repo,
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t.com",
        "commit",
        "--allow-empty",
        "-q",
        "-m",
        message,
    )


class TestCheckHeader(unittest.TestCase):
    def test_accepts_plain_types(self):
        for type_ in ("feat", "fix", "perf", "revert", "docs", "refactor", "test", "ci", "build", "chore"):
            with self.subTest(type_=type_):
                self.assertTrue(check_header(f"{type_}: does a thing"))

    def test_accepts_scope(self):
        self.assertTrue(check_header("feat(engine): add a thing"))

    def test_accepts_breaking_bang(self):
        self.assertTrue(check_header("feat!: breaking change"))
        self.assertTrue(check_header("feat(engine)!: breaking change"))

    def test_accepts_release_please_release_commit(self):
        self.assertTrue(check_header("chore(main): release 0.2.0"))

    def test_rejects_unknown_type(self):
        self.assertFalse(check_header("feature: add a thing"))

    def test_rejects_missing_colon(self):
        self.assertFalse(check_header("feat add a thing"))

    def test_rejects_empty_description(self):
        self.assertFalse(check_header("feat: "))
        self.assertFalse(check_header("feat:"))

    def test_rejects_nested_parens_scope(self):
        self.assertFalse(check_header("feat(a(b)): add a thing"))

    def test_rejects_no_space_after_colon(self):
        self.assertFalse(check_header("feat:add a thing"))


class TestCommitHeaders(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp_dir.name)
        run_git(self.repo, "init", "-q")

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_collects_non_merge_commits_in_range(self):
        commit(self.repo, "chore: init")
        run_git(self.repo, "tag", "base")
        commit(self.repo, "feat: add a thing")
        commit(self.repo, "fix: fix a thing")

        import os

        previous_cwd = os.getcwd()
        os.chdir(self.repo)
        try:
            headers = commit_headers("base..HEAD")
        finally:
            os.chdir(previous_cwd)

        subjects = [subject for _, subject in headers]
        self.assertEqual(subjects, ["fix: fix a thing", "feat: add a thing"])


class TestCLI(unittest.TestCase):
    def run_cli(self, *args, cwd=None):
        return subprocess.run(
            [sys.executable, str(SCRIPT_PATH), *args],
            cwd=cwd,
            capture_output=True,
            text=True,
        )

    def test_title_passes(self):
        result = self.run_cli("--title", "feat: add a thing")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_title_fails(self):
        result = self.run_cli("--title", "Add a thing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Add a thing", result.stderr)

    def test_range_passes(self):
        temp_dir = tempfile.TemporaryDirectory()
        try:
            repo = Path(temp_dir.name)
            run_git(repo, "init", "-q")
            commit(repo, "chore: init")
            run_git(repo, "tag", "base")
            commit(repo, "feat: add a thing")
            commit(repo, "fix: fix a thing")

            result = self.run_cli("--range", "base..HEAD", cwd=str(repo))
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            temp_dir.cleanup()

    def test_range_fails_on_bad_header(self):
        temp_dir = tempfile.TemporaryDirectory()
        try:
            repo = Path(temp_dir.name)
            run_git(repo, "init", "-q")
            commit(repo, "chore: init")
            run_git(repo, "tag", "base")
            commit(repo, "add a thing without a type")

            result = self.run_cli("--range", "base..HEAD", cwd=str(repo))
            self.assertEqual(result.returncode, 1)
            self.assertIn("add a thing without a type", result.stderr)
        finally:
            temp_dir.cleanup()

    def test_release_please_release_commit_passes_in_range(self):
        temp_dir = tempfile.TemporaryDirectory()
        try:
            repo = Path(temp_dir.name)
            run_git(repo, "init", "-q")
            commit(repo, "chore: init")
            run_git(repo, "tag", "base")
            commit(repo, "chore(main): release 0.2.0")

            result = self.run_cli("--range", "base..HEAD", cwd=str(repo))
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            temp_dir.cleanup()


if __name__ == "__main__":
    unittest.main()
