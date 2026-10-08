import contextlib
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import rehearsal_fixtures as rf  # noqa: E402


def run(args):
    return rf.main(args)


def git_out(repo, *args):
    result = subprocess.run(
        ["git", *args], cwd=str(repo), capture_output=True, text=True
    )
    if result.returncode != 0:
        raise AssertionError(f"git {args} in {repo} failed: {result.stderr}")
    return result.stdout.strip()


class FeatureBranchTests(unittest.TestCase):
    def test_simple_names(self):
        self.assertEqual(rf.feature_branch("rehearsal-a", "widget"), "yh-rehearsal-a-widget")

    def test_sanitises_special_characters(self):
        self.assertEqual(
            rf.feature_branch("rehearsal a", "widget/thing"), "yh-rehearsal-a-widget-thing"
        )

    def test_collapses_and_trims(self):
        self.assertEqual(
            rf.feature_branch("Fixture Feature: rehearsal selection", "x"),
            "yh-Fixture-Feature-rehearsal-selection-x",
        )

    def test_empty_becomes_unnamed(self):
        self.assertEqual(rf.feature_branch("!!!", "###"), "yh-unnamed-unnamed")


class BuildTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "fixtures-root"

    def build(self, project="rehearsal-a", force=False):
        args = ["build", "--root", str(self.root), "--project", project]
        if force:
            args.append("--force")
        return run(args)

    def test_build_produces_every_repo_and_check_passes(self):
        self.assertEqual(self.build(), 0)
        project_dir = self.root / "rehearsal-a"
        self.assertTrue((project_dir / rf.MARKER_NAME).is_file())
        manifest = json.loads((project_dir / "manifest.json").read_text())
        self.assertEqual(len(manifest["repos"]), 3)
        for repo in manifest["repos"]:
            self.assertTrue(Path(repo["remote"]).is_dir())
            self.assertTrue(Path(repo["path"]).is_dir())
        self.assertTrue((project_dir / "spec" / "docs" / "requirements" / "vision" / "goals.md").is_file())
        self.assertTrue((project_dir / "project-repos.toml").is_file())
        self.assertEqual(
            run(["check", "--root", str(self.root), "--project", "rehearsal-a"]), 0
        )

    def test_protected_paths_only_on_backend(self):
        self.build()
        manifest = json.loads((self.root / "rehearsal-a" / "manifest.json").read_text())
        by_name = {repo["name"]: repo for repo in manifest["repos"]}
        self.assertEqual(by_name["fixture-backend"]["protected_paths"], ["migrations/"])
        self.assertEqual(by_name["fixture-web"]["protected_paths"], [])
        self.assertEqual(by_name["fixture-mobile"]["protected_paths"], [])

    def test_scenario_refs_exist(self):
        self.build()
        remotes = self.root / "rehearsal-a" / "remotes"
        for repo in ("fixture-backend", "fixture-web", "fixture-mobile"):
            bare = remotes / f"{repo}.git"
            git_out(bare, "rev-parse", "refs/fixtures/mainline-moved")
            git_out(bare, "rev-parse", "refs/fixtures/mainline-conflict")
        git_out(remotes / "fixture-backend.git", "rev-parse", "refs/fixtures/transcription-path-touched")
        with self.assertRaises(AssertionError):
            git_out(remotes / "fixture-web.git", "rev-parse", "refs/fixtures/transcription-path-touched")

    def test_spec_layout_and_content(self):
        self.build()
        spec = self.root / "rehearsal-a" / "spec"
        goals = (spec / "docs" / "requirements" / "vision" / "goals.md").read_text()
        self.assertIn("{#g1}", goals)
        self.assertIn("{#g2}", goals)
        self.assertIn("{#g3}", goals)
        story = spec / "docs" / "requirements" / "epics" / "fixture-epic" / "stories" / "fixture-story.md"
        self.assertTrue(story.is_file())
        self.assertIn("Acceptance criteria", story.read_text())
        second_story = spec / "docs" / "requirements" / "epics" / "fixture-epic" / "stories" / "fixture-story-2.md"
        self.assertTrue(second_story.is_file())
        overview = spec / "docs" / "requirements" / "epics" / "fixture-epic" / "overview.md"
        self.assertTrue(overview.is_file())

    def test_deterministic_shas_across_two_builds(self):
        self.build()
        first = {}
        remotes = self.root / "rehearsal-a" / "remotes"
        for repo in ("fixture-backend", "fixture-web", "fixture-mobile"):
            bare = remotes / f"{repo}.git"
            first[repo] = git_out(bare, "rev-parse", "main")
        spec_sha_first = git_out(self.root / "rehearsal-a" / "spec", "rev-parse", "HEAD")

        self.build(force=True)
        remotes = self.root / "rehearsal-a" / "remotes"
        for repo in ("fixture-backend", "fixture-web", "fixture-mobile"):
            bare = remotes / f"{repo}.git"
            self.assertEqual(git_out(bare, "rev-parse", "main"), first[repo])
        spec_sha_second = git_out(self.root / "rehearsal-a" / "spec", "rev-parse", "HEAD")
        self.assertEqual(spec_sha_first, spec_sha_second)

    def test_refuses_unmarked_existing_directory(self):
        project_dir = self.root / "rehearsal-a"
        project_dir.mkdir(parents=True)
        (project_dir / "unrelated.txt").write_text("hi\n")
        self.assertEqual(self.build(), 2)
        # Nothing was touched.
        self.assertFalse((project_dir / "manifest.json").exists())

    def test_refuses_marked_directory_without_force(self):
        self.build()
        self.assertEqual(self.build(force=False), 2)

    def test_force_rebuilds_marked_directory(self):
        self.build()
        self.assertEqual(self.build(force=True), 0)

    def test_refuses_root_inside_a_git_work_tree(self):
        with tempfile.TemporaryDirectory() as outer:
            outer_path = Path(outer)
            subprocess.run(["git", "init", "--initial-branch=main", str(outer_path)], check=True, capture_output=True)
            nested_root = outer_path / "nested" / "fixtures-root"
            self.assertEqual(
                run(["build", "--root", str(nested_root), "--project", "rehearsal-a"]), 2
            )
            self.assertFalse(nested_root.exists())


class PrintedSetupCommandTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "fixtures-root"

    def build_and_capture(self, *extra):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = run(["build", "--root", str(self.root), "--project", "rehearsal-a", *extra])
        self.assertEqual(code, 0)
        return out.getvalue()

    def test_printed_setup_command_defaults_to_the_github_connection(self):
        output = self.build_and_capture()
        setup_line = next(line for line in output.splitlines() if line.startswith("yh setup --init"))
        self.assertIn("--code-hosting-connection github", setup_line)
        self.assertIn("--skip-github-check", setup_line)

    def test_printed_setup_command_names_the_chosen_connection(self):
        output = self.build_and_capture("--code-hosting-connection", "work")
        setup_line = next(line for line in output.splitlines() if line.startswith("yh setup --init"))
        self.assertIn("--code-hosting-connection work", setup_line)


class ApplyTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "fixtures-root"
        run(["build", "--root", str(self.root), "--project", "rehearsal-a"])
        self.project_dir = self.root / "rehearsal-a"

    def is_ancestor(self, repo, ancestor, descendant):
        result = subprocess.run(
            ["git", "merge-base", "--is-ancestor", ancestor, descendant],
            cwd=str(repo), capture_output=True, text=True,
        )
        return result.returncode == 0

    def test_mainline_moved_fast_forwards_and_is_idempotent(self):
        remote = self.project_dir / "remotes" / "fixture-backend.git"
        before = git_out(remote, "rev-parse", "main")
        code = run([
            "apply", "mainline-moved", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-backend",
        ])
        self.assertEqual(code, 0)
        after = git_out(remote, "rev-parse", "main")
        self.assertNotEqual(before, after)
        self.assertTrue(self.is_ancestor(remote, before, after))

        # Second apply is a no-op.
        code = run([
            "apply", "mainline-moved", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-backend",
        ])
        self.assertEqual(code, 0)
        self.assertEqual(git_out(remote, "rev-parse", "main"), after)

    def test_transcription_path_touched_only_on_backend(self):
        code = run([
            "apply", "transcription-path-touched", "--root", str(self.root), "--project", "rehearsal-a",
        ])
        self.assertEqual(code, 0)
        remote = self.project_dir / "remotes" / "fixture-backend.git"
        content = git_out(remote, "show", "main:contracts/fixture-api.json")
        self.assertIn('"version": 2', content)

    def test_mainline_conflict_moves_conflict_txt(self):
        code = run([
            "apply", "mainline-conflict", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-web",
        ])
        self.assertEqual(code, 0)
        remote = self.project_dir / "remotes" / "fixture-web.git"
        content = git_out(remote, "show", "main:conflict.txt")
        self.assertIn("moved-by-scenario", content)

    def test_predecessor_merged_creates_merge_commit(self):
        clone = self.project_dir / "repos" / "fixture-backend"
        subprocess.run(["git", "checkout", "-b", "feature-branch"], cwd=str(clone), check=True, capture_output=True)
        (clone / "feature.txt").write_text("feature work\n")
        subprocess.run(["git", "add", "-A"], cwd=str(clone), check=True, capture_output=True)
        subprocess.run(
            ["git", "commit", "-m", "feature work"], cwd=str(clone), check=True, capture_output=True,
            env={**__import__("os").environ, **rf.git_env("2026-02-01T00:00:00Z")},
        )
        subprocess.run(["git", "checkout", "main"], cwd=str(clone), check=True, capture_output=True)

        code = run([
            "apply", "predecessor-merged", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-backend", "--branch", "feature-branch",
        ])
        self.assertEqual(code, 0)
        remote = self.project_dir / "remotes" / "fixture-backend.git"
        parents = git_out(remote, "log", "-1", "--format=%P", "main").split()
        self.assertEqual(len(parents), 2)

    def test_predecessor_merged_subset_leaves_others_unmerged(self):
        for repo in ("fixture-backend", "fixture-web"):
            clone = self.project_dir / "repos" / repo
            subprocess.run(["git", "checkout", "-b", "shared-branch"], cwd=str(clone), check=True, capture_output=True)
            (clone / "shared.txt").write_text("shared\n")
            subprocess.run(["git", "add", "-A"], cwd=str(clone), check=True, capture_output=True)
            subprocess.run(
                ["git", "commit", "-m", "shared work"], cwd=str(clone), check=True, capture_output=True,
                env={**__import__("os").environ, **rf.git_env("2026-02-01T00:00:00Z")},
            )
            subprocess.run(["git", "checkout", "main"], cwd=str(clone), check=True, capture_output=True)

        code = run([
            "apply", "predecessor-merged", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-backend", "--branch", "shared-branch",
        ])
        self.assertEqual(code, 0)

        backend_remote = self.project_dir / "remotes" / "fixture-backend.git"
        web_remote = self.project_dir / "remotes" / "fixture-web.git"
        backend_branch_sha = git_out(
            self.project_dir / "repos" / "fixture-backend", "rev-parse", "shared-branch"
        )
        web_branch_sha = git_out(
            self.project_dir / "repos" / "fixture-web", "rev-parse", "shared-branch"
        )
        self.assertTrue(self.is_ancestor(backend_remote, backend_branch_sha, "main"))
        self.assertFalse(self.is_ancestor(web_remote, web_branch_sha, "main"))

    def test_predecessor_merged_refuses_missing_branch(self):
        code = run([
            "apply", "predecessor-merged", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-backend", "--branch", "does-not-exist",
        ])
        self.assertEqual(code, 2)

    def test_conflicting_branch_really_conflicts(self):
        code = run([
            "apply", "conflicting-branch", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-backend", "--branch", "feature-conflict",
        ])
        self.assertEqual(code, 0)
        clone = self.project_dir / "repos" / "fixture-backend"
        remote = self.project_dir / "remotes" / "fixture-backend.git"
        subprocess.run(["git", "fetch", "origin", "main"], cwd=str(clone), check=True, capture_output=True)
        merge_tree = subprocess.run(
            ["git", "merge-tree", "--write-tree", "origin/main", "feature-conflict"],
            cwd=str(clone), capture_output=True, text=True,
        )
        self.assertNotEqual(merge_tree.returncode, 0, merge_tree.stdout + merge_tree.stderr)

    def test_conflicting_branch_refuses_existing_branch(self):
        clone = self.project_dir / "repos" / "fixture-backend"
        subprocess.run(["git", "branch", "already-there"], cwd=str(clone), check=True, capture_output=True)
        code = run([
            "apply", "conflicting-branch", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-backend", "--branch", "already-there",
        ])
        self.assertEqual(code, 2)

    def test_predecessor_unmerged_reports_true_when_unmerged(self):
        clone = self.project_dir / "repos" / "fixture-backend"
        subprocess.run(["git", "checkout", "-b", "untouched-branch"], cwd=str(clone), check=True, capture_output=True)
        (clone / "untouched.txt").write_text("untouched\n")
        subprocess.run(["git", "add", "-A"], cwd=str(clone), check=True, capture_output=True)
        subprocess.run(
            ["git", "commit", "-m", "untouched work"], cwd=str(clone), check=True, capture_output=True,
            env={**__import__("os").environ, **rf.git_env("2026-02-01T00:00:00Z")},
        )
        subprocess.run(["git", "checkout", "main"], cwd=str(clone), check=True, capture_output=True)

        code = run([
            "apply", "predecessor-unmerged", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-backend", "--branch", "untouched-branch",
        ])
        self.assertEqual(code, 0)

    def test_feature_flag_computes_branch(self):
        code = run([
            "apply", "predecessor-unmerged", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-backend", "--feature", "Fixture Feature: rehearsal selection",
        ])
        # Branch does not exist, so it should be a skip, still exit 0.
        self.assertEqual(code, 0)

    def merge_tree_conflicts(self, clone, ref_a, ref_b):
        result = subprocess.run(
            ["git", "merge-tree", "--write-tree", ref_a, ref_b],
            cwd=str(clone), capture_output=True, text=True,
        )
        return result.returncode != 0

    def test_fast_forward_scenarios_compose_in_sequence(self):
        remote = self.project_dir / "remotes" / "fixture-backend.git"

        code = run([
            "apply", "mainline-moved", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-backend",
        ])
        self.assertEqual(code, 0)
        after_moved = git_out(remote, "rev-parse", "main")

        code = run([
            "apply", "mainline-conflict", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-backend",
        ])
        self.assertEqual(code, 0)
        after_conflict = git_out(remote, "rev-parse", "main")
        self.assertNotEqual(after_moved, after_conflict)
        self.assertTrue(self.is_ancestor(remote, after_moved, after_conflict))
        self.assertEqual(
            git_out(remote, "show", f"{after_conflict}:conflict.txt"), "conflict: moved-by-scenario"
        )
        # The earlier scenario's change survived the replay.
        self.assertEqual(git_out(remote, "show", f"{after_conflict}:NOTES.md").strip() != "", True)

        code = run([
            "apply", "transcription-path-touched", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-backend",
        ])
        self.assertEqual(code, 0)
        after_transcription = git_out(remote, "rev-parse", "main")
        self.assertNotEqual(after_conflict, after_transcription)
        self.assertTrue(self.is_ancestor(remote, after_conflict, after_transcription))
        content = git_out(remote, "show", f"{after_transcription}:contracts/fixture-api.json")
        self.assertIn('"version": 2', content)
        # Both earlier changes survived.
        self.assertEqual(
            git_out(remote, "show", f"{after_transcription}:conflict.txt"), "conflict: moved-by-scenario"
        )

    def test_replay_reapply_is_a_noop(self):
        remote = self.project_dir / "remotes" / "fixture-backend.git"
        run([
            "apply", "mainline-moved", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-backend",
        ])
        run([
            "apply", "mainline-conflict", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-backend",
        ])
        after_replay = git_out(remote, "rev-parse", "main")

        code = run([
            "apply", "mainline-conflict", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-backend",
        ])
        self.assertEqual(code, 0)
        self.assertEqual(git_out(remote, "rev-parse", "main"), after_replay)

    def test_conflicting_branch_after_mainline_moved_creates_a_real_conflict(self):
        run([
            "apply", "mainline-moved", "--root", str(self.root), "--project", "rehearsal-a",
        ])
        code = run([
            "apply", "conflicting-branch", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-web", "--branch", "feature-after-move",
        ])
        self.assertEqual(code, 0)

        clone = self.project_dir / "repos" / "fixture-web"
        subprocess.run(["git", "fetch", "origin", "main"], cwd=str(clone), check=True, capture_output=True)
        self.assertTrue(self.merge_tree_conflicts(clone, "origin/main", "feature-after-move"))

    def test_refused_conflicting_branch_leaves_no_branch_behind(self):
        # Build a repo whose remote's mainline-conflict ref has already moved beyond what a
        # replay onto the *current* main could ever cleanly reconcile, by manufacturing a
        # divergent, conflicting main by hand at the remote, so the dry-run replay fails.
        remote = self.project_dir / "remotes" / "fixture-web.git"
        clone = self.project_dir / "repos" / "fixture-web"

        scratch = Path(tempfile.mkdtemp())
        try:
            subprocess.run(["git", "clone", str(remote), str(scratch)], check=True, capture_output=True)
            subprocess.run(
                ["git", "checkout", "-B", "main"], cwd=str(scratch), check=True, capture_output=True
            )
            (scratch / "conflict.txt").write_text("conflict: hand-moved-mainline\n")
            subprocess.run(["git", "add", "-A"], cwd=str(scratch), check=True, capture_output=True)
            env = {**__import__("os").environ, **rf.git_env("2026-04-01T00:00:00Z")}
            subprocess.run(
                ["git", "commit", "-m", "hand-moved mainline"], cwd=str(scratch), check=True,
                capture_output=True, env=env,
            )
            subprocess.run(["git", "push", "origin", "main"], cwd=str(scratch), check=True, capture_output=True)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)

        code = run([
            "apply", "conflicting-branch", "--root", str(self.root), "--project", "rehearsal-a",
            "--repo", "fixture-web", "--branch", "should-not-exist",
        ])
        self.assertEqual(code, 2)
        self.assertFalse(rf.branch_exists(clone, "should-not-exist"))


class CheckTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "fixtures-root"
        run(["build", "--root", str(self.root), "--project", "rehearsal-a"])

    def test_check_passes_on_freshly_built_tree(self):
        self.assertEqual(run(["check", "--root", str(self.root), "--project", "rehearsal-a"]), 0)

    def test_check_fails_when_repo_missing(self):
        import shutil as _shutil
        _shutil.rmtree(self.root / "rehearsal-a" / "repos" / "fixture-web")
        self.assertEqual(run(["check", "--root", str(self.root), "--project", "rehearsal-a"]), 1)


if __name__ == "__main__":
    unittest.main()
