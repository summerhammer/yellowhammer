#!/usr/bin/env python3
"""
Unit tests for scripts/release/release-version.sh.

Runs the script via subprocess against a throwaway git repository created in a temp
directory, so it never touches this repository's own tags or history.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parent.parent.parent / "release" / "release-version.sh"


def run_git(repo, *args):
    subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )


def commit(repo, message):
    run_git(repo, "-c", "user.name=t", "-c", "user.email=t@t.com", "commit", "--allow-empty", "-q", "-m", message)


def run_release_version(repo, tag, env=None):
    return subprocess.run(
        [str(SCRIPT_PATH), tag],
        cwd=str(repo),
        capture_output=True,
        text=True,
        env=env,
    )


class TestReleaseVersion(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp_dir.name)
        run_git(self.repo, "init", "-q")
        commit(self.repo, "c1")
        commit(self.repo, "c2")
        run_git(self.repo, "tag", "v1.2.3")
        commit(self.repo, "c3")
        run_git(self.repo, "tag", "v1.3.0")

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_valid_tag_prints_version_and_count(self):
        result = run_release_version(self.repo, "v1.2.3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.strip().splitlines(),
            ["MARKETING_VERSION=1.2.3", "CURRENT_PROJECT_VERSION=2"],
        )

    def test_count_grows_at_later_tag(self):
        earlier = run_release_version(self.repo, "v1.2.3")
        later = run_release_version(self.repo, "v1.3.0")
        earlier_count = int(earlier.stdout.strip().splitlines()[1].split("=")[1])
        later_count = int(later.stdout.strip().splitlines()[1].split("=")[1])
        self.assertGreater(later_count, earlier_count)

    def test_rejects_tag_without_v_prefix(self):
        result = run_release_version(self.repo, "1.2.3")
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_two_part_version(self):
        run_git(self.repo, "tag", "v1.2")
        result = run_release_version(self.repo, "v1.2")
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_pre_release_suffix(self):
        run_git(self.repo, "tag", "v1.2.3-beta")
        result = run_release_version(self.repo, "v1.2.3-beta")
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_non_numeric_version(self):
        result = run_release_version(self.repo, "vx.y.z")
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_missing_tag(self):
        result = run_release_version(self.repo, "v9.9.9")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not exist", result.stderr)

    def test_appends_to_github_env(self):
        env_file = self.repo / "github_env"
        env_file.write_text("EXISTING=1\n")

        env = dict(os.environ)
        env["GITHUB_ENV"] = str(env_file)
        result = run_release_version(self.repo, "v1.2.3", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        contents = env_file.read_text()
        self.assertIn("EXISTING=1", contents)
        self.assertIn("MARKETING_VERSION=1.2.3", contents)
        self.assertIn("CURRENT_PROJECT_VERSION=2", contents)


if __name__ == "__main__":
    unittest.main()
