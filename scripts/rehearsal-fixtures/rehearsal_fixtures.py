#!/usr/bin/env python3
"""
Throwaway repositories and fixtures for rehearsal Nights (P15.2).

A rehearsal Night runs the real Acts against a scratch Linear team (`scripts/scratch-linear/`)
and throwaway repositories, and stops at three boundaries: it never dispatches an agent CLI
(result files come from fixtures bundled in the engine), never pushes, never opens a pull
request. The engine refreshes working repos with `git fetch origin <default>` (the default
branch resolved from `refs/remotes/origin/HEAD`, else `origin/main`), so each working repo
needs a local bare remote. The Spec Source is read locally at HEAD and never fetched.

This tool builds and manipulates that throwaway git fixture tree: bare "remotes", their working
clones, a local (remote-less) Spec Source repo, and a handful of pre-baked scenario commits
stored as refs that stand in for what happens to a shared remote between rehearsal Nights. See
`README.md` for the runbook, which repos/refs pair with which bundled engine result fixture, and
what each scenario is for.

Subcommands:

  build --root DIR --project ID [--project ID ...] [--force]
    Builds the full fixture set from nothing, one tree per Project, under DIR/<ID>/. Refuses
    (exit 2, nothing changed) if DIR/<ID> exists without this tool's marker file, or exists with
    the marker but --force is absent. Also refuses if DIR itself is inside a git work tree.

  apply SCENARIO --root DIR --project ID [--repo NAME ...] [--branch B | --feature NAME]
    Applies one pre-baked scenario to an already-built tree, standing in for what a human or
    another contributor does to a shared remote between rehearsal Nights. Only ever writes to
    the throwaway bare remotes and (for conflicting-branch) a throwaway clone; never touches
    Worktrees or Linear.

  check --root DIR --project ID
    Read-only. Verifies the tree is marked, every repo exists, the clones' origin points at
    their bare remote, each spec story/goal path exists in the Spec Source at HEAD, and the
    scenario refs exist. Reports what is wrong.

Exit codes: 0 ok, 1 a check failed / a scenario was refused, 2 could not run (setup or safety
refusal; nothing was changed).
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

MARKER_NAME = ".yellowhammer-rehearsal-fixtures"
PROJECT_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")

WORKING_REPOS = (
    ("fixture-backend", "backend"),
    ("fixture-web", "web"),
    ("fixture-mobile", "mobile"),
)

ALL_MOVING_REPOS = tuple(name for name, _role in WORKING_REPOS)
BACKEND_ONLY = ("fixture-backend",)

# Which working repos each pre-baked scenario ref is stored in.
SCENARIO_REPOS = {
    "mainline-moved": ALL_MOVING_REPOS,
    "transcription-path-touched": BACKEND_ONLY,
    "mainline-conflict": ALL_MOVING_REPOS,
}

FAST_FORWARD_SCENARIOS = tuple(SCENARIO_REPOS.keys())

AUTHOR_NAME = "Yellowhammer Fixtures"
AUTHOR_EMAIL = "fixtures@yellowhammer.invalid"
EPOCH = datetime(2026, 1, 1, tzinfo=timezone.utc)


class SetupFailed(Exception):
    """The tool could not be set up, or a safety guard refused: nothing was changed."""


class RunFailed(Exception):
    """A scenario or check failed."""


# MARK: - feature_branch (replicates FeatureBranch.swift's sanitising exactly)


def _sanitize(value):
    trimmed = value.strip()
    replaced = "".join(
        char if re.match(r"[A-Za-z0-9_-]", char) else "-" for char in trimmed
    )
    parts = [part for part in replaced.split("-") if part]
    result = "-".join(parts)
    return result if result else "unnamed"


def feature_branch(project, feature):
    """`yh-<project>-<feature>`, sanitised identically to
    Packages/YellowhammerKit/Sources/Domain/FeatureBranch.swift."""
    return f"yh-{_sanitize(project)}-{_sanitize(feature)}"


# MARK: - deterministic git plumbing


class DeterministicClock:
    """Produces strictly increasing, fixed (not wall-clock) ISO 8601 UTC timestamps, so two
    builds that run the same sequence of commits produce identical SHAs."""

    def __init__(self, start=EPOCH):
        self._current = start

    def next(self):
        self._current += timedelta(minutes=1)
        return self._current.strftime("%Y-%m-%dT%H:%M:%SZ")


def git_env(date):
    return {
        "GIT_AUTHOR_NAME": AUTHOR_NAME,
        "GIT_AUTHOR_EMAIL": AUTHOR_EMAIL,
        "GIT_AUTHOR_DATE": date,
        "GIT_COMMITTER_NAME": AUTHOR_NAME,
        "GIT_COMMITTER_EMAIL": AUTHOR_EMAIL,
        "GIT_COMMITTER_DATE": date,
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
    }


def git(args, cwd, env=None, check=True):
    full_env = git_env(EPOCH.strftime("%Y-%m-%dT%H:%M:%SZ"))
    if env:
        full_env.update(env)
    result = subprocess.run(
        ["git", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false", *args],
        cwd=str(cwd), env=full_env, capture_output=True, text=True,
    )
    if check and result.returncode != 0:
        raise RunFailed(
            f"git {' '.join(args)} (in {cwd}) failed: {result.stderr.strip()}"
        )
    return result


def write_file(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


def commit_all(repo_path, message, clock):
    git(["add", "-A"], cwd=repo_path)
    git(["commit", "-m", message], cwd=repo_path, env=git_env(clock.next()))


# MARK: - build


def init_bare(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    git(["init", "--bare", "--initial-branch=main", str(path)], cwd=path.parent)


def init_clone_from(remote_path, clone_path):
    clone_path.parent.mkdir(parents=True, exist_ok=True)
    git(["init", "--initial-branch=main", str(clone_path)], cwd=clone_path.parent)
    git(["remote", "add", "origin", str(remote_path)], cwd=clone_path)


def build_working_repo(project_dir, name, role, clock):
    remote = project_dir / "remotes" / f"{name}.git"
    clone = project_dir / "repos" / name
    init_bare(remote)
    init_clone_from(remote, clone)

    write_file(
        clone / "README.md",
        f"# {name} (rehearsal fixture)\n\n"
        f"Throwaway fixture repository for rehearsal Nights. role={role}. Never a real Repo.\n",
    )
    write_file(clone / "src" / "main.txt", f"fixture source file for {name}\n")
    write_file(clone / "conflict.txt", "conflict: mainline\n")
    if name == "fixture-backend":
        write_file(
            clone / "contracts" / "fixture-api.json",
            json.dumps({"contract": "fixture-api", "version": 1}, indent=2) + "\n",
        )
        write_file(
            clone / "migrations" / "0001_init.sql",
            "-- fixture migration (rehearsal fixture, never applied to a real database)\n"
            "CREATE TABLE fixture (id INTEGER PRIMARY KEY);\n",
        )

    commit_all(clone, f"Initial fixture content for {name}", clock)
    git(["push", "origin", "main"], cwd=clone)
    git(["remote", "set-head", "origin", "main"], cwd=clone)

    for ref_name, applicable in SCENARIO_REPOS.items():
        if name not in applicable:
            continue
        _make_scenario_ref(clone, ref_name, clock)

    return remote, clone


def _mutate_for_scenario(clone, ref_name):
    if ref_name == "mainline-moved":
        write_file(clone / "NOTES.md", "This mainline moved (rehearsal fixture scenario).\n")
        return "Move mainline (fixture mainline-moved)"
    if ref_name == "transcription-path-touched":
        write_file(
            clone / "contracts" / "fixture-api.json",
            json.dumps({"contract": "fixture-api", "version": 2}, indent=2) + "\n",
        )
        return "Touch the transcribed contract path (fixture transcription-path-touched)"
    if ref_name == "mainline-conflict":
        write_file(clone / "conflict.txt", "conflict: moved-by-scenario\n")
        return "Change conflict.txt on mainline (fixture mainline-conflict)"
    raise AssertionError(f"unknown scenario {ref_name}")


def _make_scenario_ref(clone, ref_name, clock):
    git(["checkout", "-b", "tmp-scenario", "main"], cwd=clone)
    message = _mutate_for_scenario(clone, ref_name)
    commit_all(clone, message, clock)
    git(["push", "origin", f"tmp-scenario:refs/fixtures/{ref_name}"], cwd=clone)
    git(["checkout", "main"], cwd=clone)
    git(["branch", "-D", "tmp-scenario"], cwd=clone)


GOALS_MD = """# Fixture Goals (rehearsal fixture, never a real goal)

## G1: Fixture goal one {#g1}

Fixture goal G1's body text.

## G2: Fixture goal two {#g2}

Fixture goal G2's body text.

## G3: Fixture goal three {#g3}

Fixture goal G3's body text.
"""

EPIC_OVERVIEW_MD = """# fixture-epic (rehearsal fixture)

This epic's business rules exist only to feed the bundled engine result fixtures used by
rehearsal Nights. It is never real product direction.

## Business rules

- A fixture-web Card transcribes the contract at `contracts/fixture-api.json` from
  fixture-backend's mainline.
- Every story below cites G1.
"""

STORY_MD_TEMPLATE = """# {title} (rehearsal fixture)

Cites G1.

## Acceptance criteria

- [ ] Fixture acceptance criterion one for {story}.
- [ ] Fixture acceptance criterion two for {story}.
"""


def build_spec_repo(project_dir, clock):
    spec_dir = project_dir / "spec"
    spec_dir.mkdir(parents=True, exist_ok=True)
    git(["init", "--initial-branch=main", str(spec_dir)], cwd=spec_dir.parent)

    write_file(spec_dir / "docs" / "requirements" / "vision" / "goals.md", GOALS_MD)
    write_file(
        spec_dir / "docs" / "requirements" / "epics" / "fixture-epic" / "overview.md",
        EPIC_OVERVIEW_MD,
    )
    write_file(
        spec_dir / "docs" / "requirements" / "epics" / "fixture-epic" / "stories" / "fixture-story.md",
        STORY_MD_TEMPLATE.format(title="fixture-story", story="fixture-story"),
    )
    write_file(
        spec_dir / "docs" / "requirements" / "epics" / "fixture-epic" / "stories" / "fixture-story-2.md",
        STORY_MD_TEMPLATE.format(title="fixture-story-2", story="fixture-story-2"),
    )

    commit_all(spec_dir, "Initial fixture spec content", clock)
    return spec_dir


def nearest_existing_ancestor(path):
    candidate = path
    while not candidate.exists():
        parent = candidate.parent
        if parent == candidate:
            break
        candidate = parent
    return candidate


def refuse_if_inside_work_tree(root):
    ancestor = nearest_existing_ancestor(root)
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=str(ancestor), capture_output=True, text=True,
    )
    if result.returncode == 0:
        raise SetupFailed(
            f"refusing to build under {root}: {ancestor} is inside a git work tree "
            f"({result.stdout.strip()})"
        )


def build_manifest(project_dir, project_id, spec_dir, repos_meta):
    return {
        "project": project_id,
        "root": str(project_dir),
        "spec_source": str(spec_dir),
        "repos": repos_meta,
        "spec": {
            "goals_path": "docs/requirements/vision/goals.md",
            "goals": ["G1", "G2", "G3"],
            "epic": "fixture-epic",
            "stories": ["fixture-story", "fixture-story-2"],
        },
        "scenario_refs": {name: list(repos) for name, repos in SCENARIO_REPOS.items()},
    }


def write_project_repos_toml(project_dir, spec_dir, repos_meta):
    lines = [f'spec_source = "{spec_dir}"', ""]
    for repo in repos_meta:
        lines.append("[[repos]]")
        lines.append(f'name = "{repo["name"]}"')
        lines.append(f'path = "{repo["path"]}"')
        lines.append(f'role = "{repo["role"]}"')
        lines.append('check = "true"')
        if repo["protected_paths"]:
            joined = ", ".join(f'"{p}"' for p in repo["protected_paths"])
            lines.append(f"protected_paths = [{joined}]")
        lines.append("")
    (project_dir / "project-repos.toml").write_text("\n".join(lines).rstrip() + "\n")


def print_setup_args(project_id, spec_dir, repos_meta):
    # Fixture repositories have a local bare repository as `origin` and no GitHub token behind it; a rehearsal
    # Night never pushes, so the GitHub check that setup otherwise makes is skipped.
    parts = [
        "yh", "setup", "--init", "--project", project_id, "--spec-source", str(spec_dir), "--skip-github-check"
    ]
    for repo in repos_meta:
        parts.append("--repo")
        parts.append(f"'{repo['name']},{repo['role']},{repo['path']},true'")
    print(" ".join(parts))


def build_one_project(root, project_id, force):
    project_dir = root / project_id
    marker = project_dir / MARKER_NAME
    if project_dir.exists():
        if not marker.is_file():
            raise SetupFailed(
                f"{project_dir} already exists and is not a rehearsal-fixtures tree "
                f"(no {MARKER_NAME}); refusing, nothing changed"
            )
        if not force:
            raise SetupFailed(
                f"{project_dir} already exists; pass --force to rebuild it, nothing changed"
            )
        shutil.rmtree(project_dir)

    project_dir.mkdir(parents=True)
    marker.write_text("This tree was built by scripts/rehearsal-fixtures/rehearsal_fixtures.py.\n")

    clock = DeterministicClock()
    repos_meta = []
    for name, role in WORKING_REPOS:
        remote, clone = build_working_repo(project_dir, name, role, clock)
        repos_meta.append({
            "name": name,
            "role": role,
            "remote": str(remote),
            "path": str(clone),
            "protected_paths": ["migrations/"] if name == "fixture-backend" else [],
        })

    spec_dir = build_spec_repo(project_dir, clock)

    manifest = build_manifest(project_dir, project_id, spec_dir, repos_meta)
    (project_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    write_project_repos_toml(project_dir, spec_dir, repos_meta)

    print(f"build: {project_id}: built at {project_dir}")
    print_setup_args(project_id, spec_dir, repos_meta)
    return manifest


def build_command(args):
    root = args.root.resolve()
    refuse_if_inside_work_tree(root)
    root.mkdir(parents=True, exist_ok=True)
    for project_id in args.project:
        build_one_project(root, project_id, args.force)
    return 0


# MARK: - apply


def load_manifest(root, project_id):
    project_dir = root / project_id
    manifest_path = project_dir / "manifest.json"
    if not manifest_path.is_file():
        raise SetupFailed(f"no manifest at {manifest_path}; build the tree first")
    with manifest_path.open() as handle:
        return project_dir, json.load(handle)


# The file each fast-forward scenario's pre-baked commit touches, used to tell "the change is
# already present on main" (a no-op) apart from "main diverged and needs a replay".
SCENARIO_TOUCHED_PATH = {
    "mainline-moved": "NOTES.md",
    "transcription-path-touched": "contracts/fixture-api.json",
    "mainline-conflict": "conflict.txt",
}

REPLAY_DATE = "2026-03-01T00:00:00Z"


def is_ancestor(repo, ancestor, descendant):
    return git(
        ["merge-base", "--is-ancestor", ancestor, descendant], cwd=repo, check=False
    ).returncode == 0


def blob_at(repo, rev, path):
    """The content of `path` at `rev`, or None if it does not exist there."""
    result = git(["show", f"{rev}:{path}"], cwd=repo, check=False)
    if result.returncode != 0:
        return None
    return result.stdout


def _replay_ref_onto_main(remote, main_sha, ref_sha, push):
    """Cherry-picks `ref_sha` onto `main_sha` in a disposable scratch clone. With push=False this
    only tests feasibility (the scratch clone, and any partial cherry-pick state, is always
    discarded — nothing is ever pushed back). With push=True, on success the result is pushed to
    the remote's main. Returns (ok, detail): detail is the new main sha on success, or a message
    describing the conflict on failure."""
    scratch = Path(tempfile.mkdtemp(prefix="scratch-replay-", dir=str(remote.parent.parent)))
    try:
        git(["clone", "--quiet", str(remote), str(scratch)], cwd=remote.parent.parent)
        git(["checkout", "-B", "main", main_sha], cwd=scratch)
        result = git(
            ["cherry-pick", ref_sha], cwd=scratch,
            env={"GIT_COMMITTER_NAME": AUTHOR_NAME, "GIT_COMMITTER_EMAIL": AUTHOR_EMAIL,
                 "GIT_COMMITTER_DATE": REPLAY_DATE},
            check=False,
        )
        if result.returncode != 0:
            git(["cherry-pick", "--abort"], cwd=scratch, check=False)
            return False, (result.stderr.strip() or result.stdout.strip())
        new_sha = git(["rev-parse", "HEAD"], cwd=scratch).stdout.strip()
        if push:
            git(["push", "origin", "main"], cwd=scratch)
        return True, new_sha
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def determine_ff_plan(remote, ref_name):
    """Read-only: decides what applying `ref_name` to `remote` would require, without writing
    anything (a would-be replay is tested in a disposable scratch clone that is always
    discarded). status is one of noop/fast-forward/replay/refused."""
    touched_path = SCENARIO_TOUCHED_PATH[ref_name]
    main_sha = git(["rev-parse", "refs/heads/main"], cwd=remote).stdout.strip()
    ref_sha = git(["rev-parse", f"refs/fixtures/{ref_name}"], cwd=remote).stdout.strip()

    if main_sha == ref_sha:
        return {"status": "noop", "ref_sha": ref_sha, "main_sha": main_sha,
                "message": f"main is already at refs/fixtures/{ref_name}"}
    if blob_at(remote, main_sha, touched_path) == blob_at(remote, ref_sha, touched_path):
        return {"status": "noop", "ref_sha": ref_sha, "main_sha": main_sha,
                "message": f"the refs/fixtures/{ref_name} change is already present on main"}
    if is_ancestor(remote, main_sha, ref_sha):
        return {"status": "fast-forward", "ref_sha": ref_sha, "main_sha": main_sha,
                "message": f"main can fast-forward to refs/fixtures/{ref_name}"}

    ok, detail = _replay_ref_onto_main(remote, main_sha, ref_sha, push=False)
    if not ok:
        return {"status": "refused", "ref_sha": ref_sha, "main_sha": main_sha,
                "message": (
                    f"main has diverged from refs/fixtures/{ref_name}'s parent, and replaying "
                    f"it onto the current main conflicts: {detail}"
                )}
    return {"status": "replay", "ref_sha": ref_sha, "main_sha": main_sha,
            "message": f"main will replay refs/fixtures/{ref_name} onto its current tip"}


def execute_ff_plan(remote, ref_name, plan):
    """Carries out a plan `determine_ff_plan` already validated as not refused."""
    if plan["status"] == "noop":
        return plan["message"]
    if plan["status"] == "fast-forward":
        git(["update-ref", "refs/heads/main", plan["ref_sha"]], cwd=remote)
        return f"main fast-forwarded to refs/fixtures/{ref_name}"
    if plan["status"] == "replay":
        ok, result = _replay_ref_onto_main(remote, plan["main_sha"], plan["ref_sha"], push=True)
        if not ok:
            raise RunFailed(
                f"replaying refs/fixtures/{ref_name} unexpectedly failed during apply: {result}"
            )
        return f"main replayed refs/fixtures/{ref_name} as {result}"
    raise AssertionError(f"cannot execute a plan with status {plan['status']!r}")


def apply_fast_forward_scenario(project_dir, manifest, scenario, explicit_repos):
    applicable = manifest["scenario_refs"][scenario]
    target_repos = explicit_repos if explicit_repos else applicable

    plans = {}
    for repo in target_repos:
        if repo not in applicable:
            continue
        remote = project_dir / "remotes" / f"{repo}.git"
        plans[repo] = determine_ff_plan(remote, scenario)

    refused = {repo: plan for repo, plan in plans.items() if plan["status"] == "refused"}
    if refused:
        for repo, plan in refused.items():
            print(f"apply: {scenario}: {repo}: REFUSED: {plan['message']}")
        print(f"apply: {scenario}: refusing; nothing changed")
        return 1

    for repo in target_repos:
        if repo not in applicable:
            print(f"apply: {scenario}: SKIP {repo}: no refs/fixtures/{scenario} in this repo")
            continue
        remote = project_dir / "remotes" / f"{repo}.git"
        message = execute_ff_plan(remote, scenario, plans[repo])
        print(f"apply: {scenario}: {repo}: {plans[repo]['status'].upper()}: {message}")
    return 0


def branch_exists(repo_path, branch):
    return git(
        ["rev-parse", "--verify", f"refs/heads/{branch}"], cwd=repo_path, check=False
    ).returncode == 0


def apply_predecessor_merged(project_dir, manifest, explicit_repos, branch):
    if not branch:
        raise SetupFailed("predecessor-merged requires --branch or --feature")
    working_repos = [repo["name"] for repo in manifest["repos"]]
    if explicit_repos:
        for repo in explicit_repos:
            clone = project_dir / "repos" / repo
            if not branch_exists(clone, branch):
                raise SetupFailed(f"branch {branch!r} does not exist in {repo}; refusing")
        target_repos = explicit_repos
    else:
        target_repos = [
            repo for repo in working_repos if branch_exists(project_dir / "repos" / repo, branch)
        ]
        if not target_repos:
            raise SetupFailed(f"branch {branch!r} does not exist in any working repo; refusing")

    for repo in target_repos:
        clone = project_dir / "repos" / repo
        remote = project_dir / "remotes" / f"{repo}.git"
        scratch = Path(tempfile.mkdtemp(prefix=f"scratch-{repo}-", dir=str(project_dir)))
        try:
            git(["clone", str(remote), str(scratch)], cwd=project_dir)
            git(["fetch", str(clone), f"{branch}:{branch}"], cwd=scratch)
            git(["checkout", "main"], cwd=scratch)
            clock = DeterministicClock()
            git(
                ["merge", "--no-ff", branch, "-m",
                 f"Merge {branch} into main (fixture predecessor-merged)"],
                cwd=scratch, env=git_env(clock.next()),
            )
            git(["push", "origin", "main"], cwd=scratch)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
        print(f"apply: predecessor-merged: {repo}: merged {branch} into main")
    return 0


def apply_conflicting_branch(project_dir, manifest, explicit_repos, branch):
    if not branch:
        raise SetupFailed("conflicting-branch requires --branch or --feature")
    if not explicit_repos or len(explicit_repos) != 1:
        raise SetupFailed("conflicting-branch requires exactly one --repo")
    repo = explicit_repos[0]
    clone = project_dir / "repos" / repo
    remote = project_dir / "remotes" / f"{repo}.git"

    # Check every precondition before any write: the branch must be absent, and the
    # mainline-conflict change must be applicable to the current remote main (fast-forward or
    # replay). If either fails, nothing is changed.
    if branch_exists(clone, branch):
        raise SetupFailed(f"branch {branch!r} already exists in {repo}; refusing")

    plan = determine_ff_plan(remote, "mainline-conflict")
    if plan["status"] == "refused":
        raise SetupFailed(
            f"cannot apply conflicting-branch to {repo}: {plan['message']}; nothing changed"
        )

    # Base the branch on main as it is *before* this apply moves it, so the branch and the new
    # main diverge over conflict.txt no matter what earlier scenarios already did to main. Fetch
    # first, while origin/main still names that pre-apply commit.
    git(["fetch", "origin", "main"], cwd=clone)
    original_main_sha = plan["main_sha"]

    message = execute_ff_plan(remote, "mainline-conflict", plan)

    git(["branch", branch, original_main_sha], cwd=clone)
    git(["checkout", branch], cwd=clone)
    write_file(clone / "conflict.txt", "conflict: from-feature-branch\n")
    clock = DeterministicClock()
    commit_all(clone, "Conflicting change on feature branch (rehearsal fixture)", clock)
    git(["checkout", "main"], cwd=clone)

    print(
        f"apply: conflicting-branch: {repo}: created {branch} from {original_main_sha[:12]}; "
        f"mainline-conflict {plan['status'].upper()}: {message}"
    )
    return 0


def apply_predecessor_unmerged(project_dir, manifest, explicit_repos, branch):
    if not branch:
        raise SetupFailed("predecessor-unmerged requires --branch or --feature")
    working_repos = [repo["name"] for repo in manifest["repos"]]
    target_repos = explicit_repos if explicit_repos else working_repos

    overall_ok = True
    for repo in target_repos:
        clone = project_dir / "repos" / repo
        if not branch_exists(clone, branch):
            print(f"apply: predecessor-unmerged: {repo}: SKIP: branch {branch!r} not found")
            continue
        git(["fetch", "origin", "main"], cwd=clone)
        ancestor_check = git(
            ["merge-base", "--is-ancestor", branch, "origin/main"], cwd=clone, check=False
        )
        if ancestor_check.returncode == 0:
            print(f"apply: predecessor-unmerged: {repo}: FAIL: {branch} IS an ancestor of origin/main")
            overall_ok = False
        else:
            print(
                f"apply: predecessor-unmerged: {repo}: PASS: {branch} is not an ancestor of "
                f"origin/main, as expected"
            )
    return 0 if overall_ok else 1


def apply_command(args):
    root = args.root.resolve()
    project_dir, manifest = load_manifest(root, args.project)

    branch = args.branch
    if args.feature:
        branch = feature_branch(args.project, args.feature)

    if args.scenario in FAST_FORWARD_SCENARIOS:
        return apply_fast_forward_scenario(project_dir, manifest, args.scenario, args.repo)
    if args.scenario == "predecessor-merged":
        return apply_predecessor_merged(project_dir, manifest, args.repo, branch)
    if args.scenario == "conflicting-branch":
        return apply_conflicting_branch(project_dir, manifest, args.repo, branch)
    if args.scenario == "predecessor-unmerged":
        return apply_predecessor_unmerged(project_dir, manifest, args.repo, branch)
    raise SetupFailed(f"unknown scenario {args.scenario!r}")


# MARK: - check


def report(ok, message):
    return f"{'PASS' if ok else 'FAIL'} {message}"


def check_command(args):
    root = args.root.resolve()
    project_dir, manifest = load_manifest(root, args.project)
    overall_ok = True

    marker = project_dir / MARKER_NAME
    ok = marker.is_file()
    print(report(ok, f"{project_dir} is marked as a rehearsal-fixtures tree"))
    overall_ok = overall_ok and ok

    for repo in manifest["repos"]:
        remote = Path(repo["remote"])
        clone = Path(repo["path"])
        ok = remote.is_dir()
        print(report(ok, f"{repo['name']}: bare remote exists at {remote}"))
        overall_ok = overall_ok and ok
        ok = clone.is_dir()
        print(report(ok, f"{repo['name']}: clone exists at {clone}"))
        overall_ok = overall_ok and ok
        if clone.is_dir():
            result = git(["remote", "get-url", "origin"], cwd=clone, check=False)
            origin_url = result.stdout.strip()
            ok = result.returncode == 0 and Path(origin_url).resolve() == remote.resolve()
            print(report(ok, f"{repo['name']}: clone's origin points at its bare remote"))
            overall_ok = overall_ok and ok

    spec_dir = Path(manifest["spec_source"])
    spec = manifest["spec"]
    paths_to_check = [spec["goals_path"]]
    epic = spec["epic"]
    paths_to_check.append(f"docs/requirements/epics/{epic}/overview.md")
    for story in spec["stories"]:
        paths_to_check.append(f"docs/requirements/epics/{epic}/stories/{story}.md")
    for path in paths_to_check:
        result = git(["show", f"HEAD:{path}"], cwd=spec_dir, check=False)
        ok = result.returncode == 0
        print(report(ok, f"spec: {path} exists in the Spec Source at HEAD"))
        overall_ok = overall_ok and ok

    for ref_name, repos in manifest["scenario_refs"].items():
        for repo in repos:
            remote = project_dir / "remotes" / f"{repo}.git"
            result = git(["rev-parse", "--verify", f"refs/fixtures/{ref_name}"], cwd=remote, check=False)
            ok = result.returncode == 0
            print(report(ok, f"{repo}: refs/fixtures/{ref_name} exists"))
            overall_ok = overall_ok and ok

    return 0 if overall_ok else 1


# MARK: - main


def project_id_type(value):
    if not PROJECT_ID_PATTERN.match(value):
        raise argparse.ArgumentTypeError(f"invalid Project id {value!r}; must match [A-Za-z0-9_-]+")
    return value


def parse_arguments(argv):
    parser = argparse.ArgumentParser(
        prog="rehearsal_fixtures.py", description=__doc__.split("\n\n")[0]
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    build_parser = subparsers.add_parser("build", help="build the fixture tree from nothing")
    build_parser.add_argument("--root", required=True, type=Path)
    build_parser.add_argument(
        "--project", action="append", required=True, type=project_id_type, dest="project"
    )
    build_parser.add_argument("--force", action="store_true")

    apply_parser = subparsers.add_parser("apply", help="apply a scenario to an existing tree")
    apply_parser.add_argument(
        "scenario",
        choices=[
            "mainline-moved", "transcription-path-touched", "mainline-conflict",
            "predecessor-merged", "conflicting-branch", "predecessor-unmerged",
        ],
    )
    apply_parser.add_argument("--root", required=True, type=Path)
    apply_parser.add_argument("--project", required=True, type=project_id_type)
    apply_parser.add_argument("--repo", action="append", default=None)
    branch_group = apply_parser.add_mutually_exclusive_group()
    branch_group.add_argument("--branch")
    branch_group.add_argument("--feature")

    check_parser = subparsers.add_parser("check", help="read-only: verify the fixture tree")
    check_parser.add_argument("--root", required=True, type=Path)
    check_parser.add_argument("--project", required=True, type=project_id_type)

    return parser.parse_args(argv)


def main(argv=None):
    args = parse_arguments(argv if argv is not None else sys.argv[1:])
    try:
        if args.command == "build":
            return build_command(args)
        if args.command == "apply":
            return apply_command(args)
        return check_command(args)
    except SetupFailed as error:
        print(f"rehearsal-fixtures: cannot run: {error}", file=sys.stderr)
        return 2
    except RunFailed as error:
        print(f"rehearsal-fixtures: failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
