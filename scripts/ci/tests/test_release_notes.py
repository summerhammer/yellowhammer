#!/usr/bin/env python3
"""
Unit tests for scripts/release/release-notes.sh.

Runs the script via subprocess against a throwaway git repository created in a temp
directory, so it never touches this repository's own tags or history. Bash, python3
and git only, so this also runs on ubuntu-latest (see .github/workflows/release-scripts.yml).
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parent.parent.parent / "release" / "release-notes.sh"


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


def run_release_notes(repo, tag, previous_tag=None):
    argv = [str(SCRIPT_PATH), tag]
    if previous_tag is not None:
        argv.append(previous_tag)
    return subprocess.run(argv, cwd=str(repo), capture_output=True, text=True)


class TestReleaseNotes(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp_dir.name)
        run_git(self.repo, "init", "-q")

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_no_spec_lines_reports_none_cited_and_no_stories_section(self):
        commit(self.repo, "init")
        run_git(self.repo, "tag", "v1.0.0")

        result = run_release_notes(self.repo, "v1.0.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Built against spec commit: none cited.", result.stdout)
        self.assertNotIn("### Stories", result.stdout)
        self.assertIn("shasum -a 256 -c SHA256SUMS", result.stdout)

    def test_collects_dedups_and_sorts_story_ids(self):
        commit(self.repo, "init")
        run_git(self.repo, "tag", "v0.9.0")
        commit(self.repo, "story z\n\nSpec: zepic/story1 @ aaaaaaa")
        commit(self.repo, "story a\n\nSpec: aepic/story1 @ aaaaaaa")
        commit(self.repo, "story a again\n\nSpec: aepic/story1 @ aaaaaaa")
        run_git(self.repo, "tag", "v1.0.0")

        result = run_release_notes(self.repo, "v1.0.0", "v0.9.0")
        self.assertEqual(result.returncode, 0, result.stderr)

        stories_section = result.stdout.split("### Stories")[1].split("\n##")[0]
        story_lines = [line.strip("- ").strip() for line in stories_section.strip().splitlines()]
        self.assertEqual(story_lines, ["aepic/story1", "zepic/story1"])

    def test_picks_newest_spec_sha_and_lists_multiple(self):
        commit(self.repo, "init")
        run_git(self.repo, "tag", "v0.9.0")
        commit(self.repo, "story1\n\nSpec: epic/story1 @ aaaaaaa")
        commit(self.repo, "story2\n\nSpec: epic/story2 @ ccccccc")
        run_git(self.repo, "tag", "v1.0.0")

        result = run_release_notes(self.repo, "v1.0.0", "v0.9.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Built against spec commit ccccccc.", result.stdout)
        self.assertIn("### Spec commits cited", result.stdout)
        self.assertIn("- aaaaaaa", result.stdout)
        self.assertIn("- ccccccc", result.stdout)

    def test_single_spec_sha_has_no_commits_cited_section(self):
        commit(self.repo, "init")
        run_git(self.repo, "tag", "v0.9.0")
        commit(self.repo, "story1\n\nSpec: epic/story1 @ aaaaaaa")
        commit(self.repo, "story2\n\nSpec: epic/story2 @ aaaaaaa")
        run_git(self.repo, "tag", "v1.0.0")

        result = run_release_notes(self.repo, "v1.0.0", "v0.9.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("### Spec commits cited", result.stdout)

    def test_previous_tag_range_excludes_older_stories(self):
        commit(self.repo, "init")
        run_git(self.repo, "tag", "v0.8.0")
        commit(self.repo, "old story\n\nSpec: epic/old-story @ 1111111")
        run_git(self.repo, "tag", "v0.9.0")
        commit(self.repo, "new story\n\nSpec: epic/new-story @ 2222222")
        run_git(self.repo, "tag", "v1.0.0")

        result = run_release_notes(self.repo, "v1.0.0", "v0.9.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("epic/new-story", result.stdout)
        self.assertNotIn("epic/old-story", result.stdout)

    def test_default_previous_tag_is_most_recent_reachable_v_tag(self):
        commit(self.repo, "init")
        run_git(self.repo, "tag", "v0.9.0")
        commit(self.repo, "old story\n\nSpec: epic/old-story @ 1111111")
        run_git(self.repo, "tag", "v1.0.0")
        commit(self.repo, "new story\n\nSpec: epic/new-story @ 2222222")
        run_git(self.repo, "tag", "v1.1.0")

        result = run_release_notes(self.repo, "v1.1.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("epic/new-story", result.stdout)
        self.assertNotIn("epic/old-story", result.stdout)

    def test_no_previous_tag_covers_from_root_commit(self):
        commit(self.repo, "init\n\nSpec: epic/root-story @ 3333333")
        commit(self.repo, "second")
        run_git(self.repo, "tag", "v1.0.0")

        result = run_release_notes(self.repo, "v1.0.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("epic/root-story", result.stdout)

    def test_rejects_missing_tag(self):
        commit(self.repo, "init")
        result = run_release_notes(self.repo, "v9.9.9")
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_missing_previous_tag(self):
        commit(self.repo, "init")
        run_git(self.repo, "tag", "v1.0.0")
        result = run_release_notes(self.repo, "v1.0.0", "v0.0.0-does-not-exist")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
