"""
The suite's 13 scenarios (P15.3): the scenario registry, shared helpers, and scenarios 1-6.
Scenarios 7-13 live in `scenarios_recovery.py` (imported at the bottom of this module so that
`import scenarios` alone populates the whole registry).
"""

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

import suite_env
from suite_env import night

LAND_FINISHED = "rehearsal Night: the land Act finished"


@dataclass(frozen=True)
class ScenarioSpec:
    number: int
    title: str
    needs_operator: bool
    func: object


SCENARIOS = {}


def scenario(number, title, needs_operator=False):
    def decorator(func):
        SCENARIOS[number] = ScenarioSpec(number, title, needs_operator, func)
        return func
    return decorator


def _not_implemented(env, checks):
    checks.expect(False, "not implemented in this slice")


# MARK: - 1. Idle first Night


@scenario(1, "Idle first Night")
def scenario_1(env, checks):
    project_id = "rehearsal-suite-a"
    slug = "01-idle-first-night"

    manifest = suite_env.reset_project(env, project_id)
    suite_env.write_scenario_project_file(env, project_id, manifest)

    n1 = night(1)
    returncode, output, log_path = env.yh.run_rehearse(
        slug, project_id, night=n1,
        result_fixtures=[("selection", "selection-no-selectable-feature")],
    )
    checks.require(returncode == 0, f"rehearse exited 0 (got {returncode}); see {log_path}")
    checks.require(LAND_FINISHED in output, "output names the land Act finished")

    snap = env.snapshot(slug, project_id, "after-rehearse")
    nights = snap.nights()
    checks.require(len(nights) == 1, f"exactly one Night recorded (found {len(nights)})")
    night_row = nights[0]
    checks.expect(night_row["verdict"] == "idle", f"Night verdict is idle (got {night_row['verdict']!r})")
    checks.expect(night_row["state"] == "closed", f"Night state is closed (got {night_row['state']!r})")

    no_work = snap.events(type="AuthoringNoWorkAvailable")
    checks.expect(len(no_work) == 1, f"exactly one AuthoringNoWorkAvailable (found {len(no_work)})")

    idle_events = snap.events(type="ActIdle")
    build_idle = [e for e in idle_events if e["act"] == "build"]
    land_idle = [e for e in idle_events if e["act"] == "land"]
    checks.expect(
        len(build_idle) == 1 and build_idle[0]["payload"].get("reason") == "no_feature_in_flight",
        "build recorded ActIdle(no_feature_in_flight)",
    )
    checks.expect(
        len(land_idle) == 1 and land_idle[0]["payload"].get("reason") == "no_feature_in_flight",
        "land recorded ActIdle(no_feature_in_flight)",
    )

    checks.expect(len(snap.features()) == 0, "no Feature rows")
    checks.expect(len(snap.cards()) == 0, "no Card rows")
    checks.expect(len(snap.worktrees()) == 0, "no Worktree rows")

    checks.expect(len(snap.events(type="NightCardOpened")) >= 1, "NightCardOpened recorded")
    checks.expect(len(snap.events(type="NightCardCompleted")) >= 1, "NightCardCompleted recorded")

    issue_id = night_row.get("night_card_issue_id")
    checks.require(bool(issue_id), "the Night has a night_card_issue_id")
    issue = env.linear.issue(issue_id)
    checks.expect(
        issue["state"]["type"] == "completed",
        f"the Night Card issue is in a completed-type state (got {issue['state']})",
    )


# MARK: - 2. First Night authoring Feature 1 across three repos


@scenario(2, "First Night authoring Feature 1 across three repos")
def scenario_2(env, checks):
    project_id = "rehearsal-suite-a"
    slug = "02-feature-1-three-repos"

    manifest = suite_env.reset_project(env, project_id)
    suite_env.write_scenario_project_file(env, project_id, manifest)

    n1 = night(1)
    returncode, output, log_path = env.yh.run_rehearse(
        slug, project_id, night=n1,
        result_fixtures=[
            ("selection", "selection-selected-three-repos"),
            ("breakdown", "breakdown-drafted-three-repos"),
        ],
    )
    checks.require(returncode == 0, f"rehearse exited 0 (got {returncode}); see {log_path}")
    checks.require(LAND_FINISHED in output, "output names the land Act finished")

    snap = env.snapshot(slug, project_id, "after-rehearse")

    features = snap.features()
    checks.require(len(features) == 1, f"exactly one Feature recorded (found {len(features)})")
    feature = features[0]

    selected_events = snap.events(type="FeatureSelected")
    checks.require(len(selected_events) >= 1, "FeatureSelected recorded")
    feature_name = selected_events[0]["payload"].get("name")
    checks.require(bool(feature_name), "FeatureSelected names the Feature")
    expected_branch = suite_env.feature_branch(project_id, feature_name)
    recorded = {r["repository"]: r["branch"] for r in snap.feature_repositories() if r["feature_id"] == feature["id"]}
    for repo in manifest["repos"]:
        checks.expect(
            suite_env.is_reported_feature_branch(recorded.get(repo["name"]), expected_branch),
            f"{repo['name']}: recorded Feature Branch {recorded.get(repo['name'])!r} is {expected_branch!r} or a prefixed form",
        )

    cards = snap.cards()
    checks.require(len(cards) > 0, "at least one Card recorded")
    non_done = [card for card in cards if card["state"] != "Done"]
    checks.expect(not non_done, f"every Card is Done (found non-Done: {non_done})")

    for card in cards:
        issue = env.linear.issue(card["issue_id"])
        parent = issue.get("parent") or {}
        checks.expect(
            parent.get("id") == feature["issue_id"],
            f"Card {card['issue_id']}'s board parent is the Feature Issue (got {parent})",
        )

    repositories = {repo["name"] for repo in manifest["repos"]}
    worktrees = snap.worktrees()
    held = [w for w in worktrees if w.get("released_at") is None]
    held_repositories = {w["repository"] for w in held}
    checks.expect(
        held_repositories == repositories,
        f"exactly one held Worktree per repository (got {held_repositories}, expected {repositories})",
    )
    checks.expect(len(held) == len(repositories), f"no repository holds more than one Worktree (held={held})")

    for worktree in held:
        path = worktree["path"]
        checks.expect(Path(path).exists(), f"Worktree path exists: {path}")
        result = subprocess.run(
            ["git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True
        )
        branch = result.stdout.strip()
        target = recorded.get(worktree["repository"])
        checks.expect(
            result.returncode == 0 and branch == target,
            f"{path}: checked out branch is {target!r} (got {branch!r})",
        )

    checks.expect(
        len(snap.events(type="RehearsalFixtureAnswered")) >= 1, "at least one RehearsalFixtureAnswered"
    )
    checks.expect(
        len(snap.events(type="AgentCLIProcessSpawned")) == 0, "zero AgentCLIProcessSpawned"
    )

    land_steps = snap.events(type="LandStep")
    for repo_name in repositories:
        for step in ("push", "open-pull-request"):
            matches = [
                e for e in land_steps
                if e["payload"].get("step") == step and e["payload"].get("repository") == repo_name
            ]
            checks.expect(
                bool(matches) and all(e["payload"].get("outcome") == "rehearsal-boundary" for e in matches),
                f"{repo_name}: LandStep {step} outcome is rehearsal-boundary (found {matches})",
            )

    for repo in manifest["repos"]:
        remote = repo["remote"]
        target = recorded.get(repo["name"]) or expected_branch
        result = subprocess.run(
            ["git", "-C", remote, "rev-parse", "--verify", f"refs/heads/{target}"],
            capture_output=True, text=True,
        )
        checks.expect(
            result.returncode != 0,
            f"no bare remote ({remote}) carries {target!r}",
        )

    checks.expect(len(snap.events(type="CycleLanded")) >= 1, "CycleLanded recorded")

    nights = snap.nights()
    checks.expect(
        any(n["night_start"] == n1 and n["state"] == "closed" for n in nights),
        f"Night {n1} is closed (nights={nights})",
    )



# MARK: - helpers shared by several scenarios


def _held_worktrees_for(snap, feature_issue_id):
    features = {f["issue_id"]: f for f in snap.features()}
    feature = features[feature_issue_id]
    return [w for w in snap.worktrees() if w["feature_id"] == feature["id"] and w.get("released_at") is None]


def _feature_row(snap, feature_issue_id):
    for feature in snap.features():
        if feature["issue_id"] == feature_issue_id:
            return feature
    return None


def _cards_of_repository(snap, feature_row_id, repository):
    cards = [
        c for c in snap.cards()
        if c["repository"] == repository
        and snap.rows("SELECT feature_id FROM cycle WHERE id = ?", (c["cycle_id"],))[0]["feature_id"] == feature_row_id
    ]
    return sorted(cards, key=lambda c: c["authored_order"])


# MARK: - 3. Quiet Night: predecessor not merged; then merged; then partially merged


@scenario(3, "Quiet Night: predecessor not merged; then merged; then partially merged")
def scenario_3(env, checks):
    project_id = "rehearsal-suite-a"
    slug = "03-quiet-night-predecessor"
    repos = ("fixture-backend", "fixture-web")
    # Every author Act of this scenario draws the two-repository Feature, so each Feature's landing
    # is judged in both repositories — a later Night that selects draws the same pair.
    two_repo_fixtures = [
        ("selection", "selection-selected-with-contract"),
        ("breakdown", "breakdown-drafted-with-contract"),
    ]

    manifest = suite_env.reset_project(env, project_id)
    suite_env.write_scenario_project_file(env, project_id, manifest)

    n1 = night(1)
    returncode, output, log_path = env.yh.run_rehearse(
        slug, project_id, night=n1,
        result_fixtures=two_repo_fixtures,
    )
    checks.require(returncode == 0, f"N1 rehearse exits 0 (got {returncode}); see {log_path}")

    snap1 = env.snapshot(slug, project_id, "after-n1")
    selected = snap1.events(type="FeatureSelected")
    checks.require(len(selected) >= 1, "N1: FeatureSelected recorded")
    f1_name = selected[0]["payload"].get("name")
    features = snap1.features()
    checks.require(len(features) == 1, f"N1: exactly one Feature recorded (found {len(features)})")
    f1_issue_id = features[0]["issue_id"]
    held = _held_worktrees_for(snap1, f1_issue_id)
    checks.require(len(held) >= 1, "N1: at least one held Worktree for F1")
    for worktree in held:
        suite_env.stand_in_commit(worktree["path"], f"n1-{worktree['repository']}")

    n2 = night(2)
    env.yh.run_act(slug, "author", project_id, night=n2, result_fixtures=two_repo_fixtures, label="n2-author")
    env.yh.run_act(slug, "build", project_id, night=n2, label="n2-build")
    returncode, output, log_path = env.yh.run_act(slug, "land", project_id, night=n2, label="n2-land")
    checks.expect(returncode == 0, f"N2 land exits 0 (got {returncode}); see {log_path}")

    snap2 = env.snapshot(slug, project_id, "after-n2")
    n2_id = snap2.night_id(n2)
    checks.require(n2_id is not None, "N2: Night recorded")
    not_landed = [e for e in snap2.events(type="AuthoringPredecessorNotLanded") if e["night_id"] == n2_id]
    checks.require(len(not_landed) >= 1, "N2: AuthoringPredecessorNotLanded recorded")
    named_repos = set(not_landed[0]["payload"].get("repositories", "").split("\u001f"))
    checks.expect(named_repos == set(repos), f"N2: AuthoringPredecessorNotLanded names both repositories (got {named_repos})")
    checks.expect(
        not any(e["night_id"] == n2_id for e in snap2.events(type="FeatureSelected")),
        "N2: no FeatureSelected",
    )
    observed = [e for e in snap2.events(type="PredecessorAncestryObserved") if e["night_id"] == n2_id]
    checks.require(len(observed) >= 1, "N2: PredecessorAncestryObserved recorded")
    unmerged = set(observed[0]["payload"].get("unmerged_repositories", "").split("\u001f"))
    checks.expect(unmerged == set(repos), f"N2: both repositories unmerged (got {unmerged})")

    suite_env.apply_fixture(env.root, project_id, "predecessor-merged", feature=f1_name)

    n3 = night(3)
    env.yh.run_act(
        slug, "author", project_id, night=n3, feature="Fixture Feature 2", result_fixtures=two_repo_fixtures,
        label="n3-author",
    )
    env.yh.run_act(slug, "build", project_id, night=n3, label="n3-build")
    returncode, output, log_path = env.yh.run_act(slug, "land", project_id, night=n3, label="n3-land")
    checks.expect(returncode == 0, f"N3 land exits 0 (got {returncode}); see {log_path}")

    snap3 = env.snapshot(slug, project_id, "after-n3")
    n3_id = snap3.night_id(n3)
    checks.require(n3_id is not None, "N3: Night recorded")
    n3_selected = [e for e in snap3.events(type="FeatureSelected") if e["night_id"] == n3_id]
    checks.require(len(n3_selected) >= 1, "N3: FeatureSelected recorded")
    checks.expect(
        n3_selected[0]["payload"].get("name") == "Fixture Feature 2",
        f"N3: FeatureSelected names Fixture Feature 2 (got {n3_selected[0]['payload'].get('name')!r})",
    )
    checks.expect(
        any(e["night_id"] == n3_id for e in snap3.events(type="FeatureAuthored")), "N3: FeatureAuthored recorded"
    )
    checks.expect(
        not any(e["night_id"] == n3_id for e in snap3.events(type="AuthoringPredecessorNotLanded")),
        "N3: no AuthoringPredecessorNotLanded",
    )
    f1_row = _feature_row(snap3, f1_issue_id)
    checks.require(f1_row is not None, "N3: F1 still recorded")
    landings = snap3.rows("SELECT * FROM feature_landing WHERE feature_id = ?", (f1_row["id"],))
    landed_repos = {row["repository"] for row in landings}
    checks.expect(landed_repos == set(repos), f"N3: feature_landing rows for F1 in both repos (got {landed_repos})")

    f2_row = None
    for feature in snap3.features():
        if feature["issue_id"] != f1_issue_id:
            f2_row = feature
    checks.require(f2_row is not None, "N3: F2 recorded")
    f2_issue_id = f2_row["issue_id"]
    held2 = _held_worktrees_for(snap3, f2_issue_id)
    checks.require(len(held2) >= 1, "N3: at least one held Worktree for F2")
    for worktree in held2:
        suite_env.stand_in_commit(worktree["path"], f"n3-{worktree['repository']}")

    suite_env.apply_fixture(env.root, project_id, "predecessor-merged", feature="Fixture Feature 2", repo="fixture-backend")

    n4 = night(4)
    env.yh.run_act(slug, "author", project_id, night=n4, result_fixtures=two_repo_fixtures, label="n4-author")
    env.yh.run_act(slug, "build", project_id, night=n4, label="n4-build")
    returncode, output, log_path = env.yh.run_act(slug, "land", project_id, night=n4, label="n4-land")
    checks.expect(returncode == 0, f"N4 land exits 0 (got {returncode}); see {log_path}")

    snap4 = env.snapshot(slug, project_id, "after-n4")
    n4_id = snap4.night_id(n4)
    checks.require(n4_id is not None, "N4: Night recorded")
    n4_not_landed = [e for e in snap4.events(type="AuthoringPredecessorNotLanded") if e["night_id"] == n4_id]
    checks.require(len(n4_not_landed) >= 1, "N4: AuthoringPredecessorNotLanded recorded")
    n4_named = set(n4_not_landed[0]["payload"].get("repositories", "").split("\u001f"))
    checks.expect(n4_named == {"fixture-web"}, f"N4: names only fixture-web (got {n4_named})")
    n4_observed = [e for e in snap4.events(type="PredecessorAncestryObserved") if e["night_id"] == n4_id]
    checks.require(len(n4_observed) >= 1, "N4: PredecessorAncestryObserved recorded")
    n4_merged = set(n4_observed[0]["payload"].get("merged_repositories", "").split("\u001f"))
    n4_unmerged = set(n4_observed[0]["payload"].get("unmerged_repositories", "").split("\u001f"))
    checks.expect(n4_merged == {"fixture-backend"}, f"N4: fixture-backend merged (got {n4_merged})")
    checks.expect(n4_unmerged == {"fixture-web"}, f"N4: fixture-web unmerged (got {n4_unmerged})")
    f2_landings = snap4.rows("SELECT * FROM feature_landing WHERE feature_id = ?", (f2_row["id"],))
    f2_landed_repos = {row["repository"] for row in f2_landings}
    checks.expect(
        f2_landed_repos == {"fixture-backend"}, f"N4: feature_landing row for F2 in fixture-backend only (got {f2_landed_repos})"
    )


# MARK: - 4. Mid-lane block with a Partial Landing announcement rendered


@scenario(4, "Mid-lane block with a Partial Landing announcement rendered")
def scenario_4(env, checks):
    project_id = "rehearsal-suite-a"
    slug = "04-mid-lane-block"

    manifest = suite_env.reset_project(env, project_id)
    suite_env.write_scenario_project_file(env, project_id, manifest, limits={"attempts_per_card": 1})

    n1 = night(1)
    returncode, output, log_path = env.yh.run_act(
        slug, "author", project_id, night=n1,
        result_fixtures=[
            ("selection", "selection-selected-three-repos"),
            ("breakdown", "breakdown-drafted-three-repos"),
        ],
    )
    checks.require(returncode == 0, f"author exits 0 (got {returncode}); see {log_path}")

    snap_after_author = env.snapshot(slug, project_id, "after-author")
    features = snap_after_author.features()
    checks.require(len(features) == 1, f"exactly one Feature recorded (found {len(features)})")
    feature = features[0]
    backend_cards = _cards_of_repository(snap_after_author, feature["id"], "fixture-backend")
    checks.require(len(backend_cards) >= 3, f"at least three fixture-backend Cards (found {len(backend_cards)})")
    m_card = backend_cards[1]
    third_card = backend_cards[2]

    returncode, output, log_path = env.yh.run_act(
        slug, "build", project_id, night=n1,
        result_fixtures=[("worker", m_card["issue_id"], "worker-failed")],
    )
    checks.require(returncode == 0, f"build exits 0 (got {returncode}); see {log_path}")

    snap_after_build = env.snapshot(slug, project_id, "after-build")
    cards = {c["issue_id"]: c for c in snap_after_build.cards()}
    m_after = cards[m_card["issue_id"]]
    third_after = cards[third_card["issue_id"]]
    checks.expect(bool(m_after.get("block_reason")), f"M is Blocked (block_reason={m_after.get('block_reason')!r})")
    hole_events = [
        e for e in snap_after_build.events(type="LaneHoleRecorded") if e["payload"].get("card_id") == str(m_after["id"])
    ]
    checks.expect(len(hole_events) >= 1, f"LaneHoleRecorded for M (found {len(hole_events)})")
    checks.expect(third_after["state"] == "Done", f"the third backend Card is Done (got {third_after['state']!r})")

    m_transition_ids = [
        e["id"] for e in snap_after_build.events(type="CardStateTransitioned")
        if e["payload"].get("card_id") == str(m_after["id"]) and e["payload"].get("to_state") == "Blocked"
    ]
    third_run_step_ids = [
        e["id"] for e in snap_after_build.events(type="CardRunStep")
        if e["payload"].get("card_id") == str(third_after["id"]) and e["payload"].get("step") == "attempt-started"
    ]
    checks.expect(
        bool(m_transition_ids) and bool(third_run_step_ids) and min(third_run_step_ids) > min(m_transition_ids),
        "the third Card's attempt-started CardRunStep is recorded after M's transition to Blocked",
    )

    non_done_others = [
        c for c in snap_after_build.cards() if c["issue_id"] not in (m_after["issue_id"],) and c["state"] != "Done"
    ]
    checks.expect(not non_done_others, f"every other Card is Done (found non-Done: {non_done_others})")

    m_issue = env.linear.issue(m_after["issue_id"])
    checks.expect(m_issue["state"]["name"] == "Blocked", f"the board shows M's state as Blocked (got {m_issue['state']})")

    returncode, output, log_path = env.yh.run_act(slug, "land", project_id, night=n1)
    checks.require(returncode == 0, f"land exits 0 (got {returncode}); see {log_path}")

    snap_after_land = env.snapshot(slug, project_id, "after-land")
    checks.expect(len(snap_after_land.events(type="CycleLanded")) >= 1, "CycleLanded recorded")
    checks.expect(len(snap_after_land.events(type="FeatureReturned")) >= 1, "FeatureReturned recorded")
    cycle_rows = snap_after_land.rows("SELECT * FROM cycle WHERE feature_id = ?", (feature["id"],))
    checks.require(len(cycle_rows) == 1, "exactly one cycle row for the Feature")
    checks.expect(cycle_rows[0]["archived_at"] is None, "the cycle is not archived")
    archive_steps = [
        e for e in snap_after_land.events(type="LandStep") if e["payload"].get("step") == "archive-cycle"
    ]
    checks.expect(
        bool(archive_steps) and archive_steps[-1]["payload"].get("outcome") == "skipped",
        f"the archive-cycle LandStep is skipped (found {archive_steps})",
    )
    feature_issue = env.linear.issue(feature["issue_id"])
    description = (feature_issue.get("description") or "")
    checks.expect(
        "**partial · " in description, "the Feature Issue's description leads with the Roll-up word 'partial'"
    )
    # The Roll-up names each Card by its title (the Journal now records one, reconciled by the Delta
    # Read), so the hole is named by M's title and its state, not its issue id.
    m_title = m_after["title"]
    checks.expect(
        f"{m_title} — Blocked" in description,
        f"the Feature Issue's Roll-up names M ({m_title}) as Blocked",
    )
    checks.expect(
        "1 blocked" in description.lower(), "the Roll-up sentence counts the one blocked Card"
    )


# MARK: - 5. Waiting on You answered before landing, and after landing (banked)


@scenario(5, "Waiting on You answered before landing, and after landing (banked)", needs_operator=True)
def scenario_5(env, checks):
    project_id = "rehearsal-suite-a"
    slug = "05a-answered-before-landing"

    manifest = suite_env.reset_project(env, project_id)
    suite_env.write_scenario_project_file(env, project_id, manifest)

    n1 = night(1)
    env.yh.run_act(slug, "author", project_id, night=n1)
    returncode, output, log_path = env.yh.run_act(
        slug, "build", project_id, night=n1, result_fixtures=[("worker", "worker-question")]
    )
    checks.require(returncode == 0, f"build exits 0 (got {returncode}); see {log_path}")

    snap1 = env.snapshot(slug, project_id, "after-first-build")
    cards = snap1.cards()
    checks.require(len(cards) == 1, f"exactly one Card (found {len(cards)})")
    card = cards[0]
    checks.expect(
        card["state"] == "Waiting on You" and card.get("waiting_reason") == "question",
        f"the Card is Waiting on You / question (got state={card['state']!r} waiting_reason={card.get('waiting_reason')!r})",
    )
    questions = snap1.rows("SELECT * FROM card_question WHERE card_id = ?", (card["id"],))
    checks.require(len(questions) >= 1, "a card_question row exists")
    checks.expect(len(snap1.events(type="CardQuestionAsked")) >= 1, "CardQuestionAsked recorded")
    board_card = env.linear.issue(card["issue_id"])
    checks.expect(board_card["state"]["name"] == "Waiting on You", f"board state is Waiting on You (got {board_card['state']})")

    comment_client_id = (questions[0].get("comment_client_id") or "").lower()
    comments = env.linear.comments(card["issue_id"])
    question_comment = next((c for c in comments if c["id"].lower() == comment_client_id), None)
    checks.require(question_comment is not None, "a board comment id equals card_question.comment_client_id")

    env.operator_client.reply(card["issue_id"], question_comment["id"], "Please proceed with the fixture.")

    returncode, output, log_path = env.yh.run_act(slug, "build", project_id, night=n1, label="build-after-reply")
    checks.require(returncode == 0, f"second build exits 0 (got {returncode}); see {log_path}")

    snap2 = env.snapshot(slug, project_id, "after-second-build")
    replies = [
        e for e in snap2.events(type="WaitingOnYouReplyRecorded") if e["payload"].get("disposition") == "answer"
    ]
    checks.expect(len(replies) >= 1, "WaitingOnYouReplyRecorded disposition answer")
    card_reply_rows = snap2.rows("SELECT * FROM card_reply WHERE card_id = ?", (card["id"],))
    checks.expect(
        any(row.get("applied_at") for row in card_reply_rows), "card_reply.applied_at is set"
    )
    card_after = next(c for c in snap2.cards() if c["id"] == card["id"])
    checks.expect(card_after["state"] == "Done", f"the Card is Done (got {card_after['state']!r})")
    comments_after = env.linear.comments(card["issue_id"])
    checks.expect(
        any(c["body"].startswith("**It runs on the next build Act.**") for c in comments_after),
        "an app comment acknowledges with 'It runs on the next build Act.'",
    )

    returncode, output, log_path = env.yh.run_act(slug, "land", project_id, night=n1)
    checks.require(returncode == 0, f"land exits 0 (got {returncode}); see {log_path}")
    snap3 = env.snapshot(slug, project_id, "after-land")
    checks.expect(len(snap3.events(type="CycleLanded")) >= 1, "CycleLanded recorded")

    # Part (b): the reply arrives after the Night has already landed, so it is banked instead.
    slug_b = "05b-banked-after-landing"
    manifest = suite_env.reset_project(env, project_id)
    suite_env.write_scenario_project_file(env, project_id, manifest)

    env.yh.run_act(slug_b, "author", project_id, night=n1, label="b-author")
    env.yh.run_act(
        slug_b, "build", project_id, night=n1, result_fixtures=[("worker", "worker-question")], label="b-build"
    )
    returncode, output, log_path = env.yh.run_act(slug_b, "land", project_id, night=n1, label="b-land")
    checks.require(returncode == 0, f"(b) land exits 0 (got {returncode}); see {log_path}")

    snap_b1 = env.snapshot(slug_b, project_id, "b-after-land")
    checks.expect(len(snap_b1.events(type="CycleLanded")) >= 1, "(b) CycleLanded recorded")
    checks.expect(len(snap_b1.events(type="FeatureReturned")) >= 1, "(b) FeatureReturned recorded")
    b_cards = snap_b1.cards()
    checks.require(len(b_cards) == 1, f"(b) exactly one Card (found {len(b_cards)})")
    b_card = b_cards[0]
    b_features = snap_b1.features()
    checks.require(len(b_features) == 1, "(b) exactly one Feature recorded")
    b_held = _held_worktrees_for(snap_b1, b_features[0]["issue_id"])
    backend_worktree = next((w for w in b_held if w["repository"] == "fixture-backend"), None)
    checks.require(backend_worktree is not None, "(b) a held fixture-backend Worktree exists")
    suite_env.stand_in_commit(backend_worktree["path"], "b-fixture-backend")

    b_questions = snap_b1.rows("SELECT * FROM card_question WHERE card_id = ?", (b_card["id"],))
    checks.require(len(b_questions) >= 1, "(b) a card_question row exists")
    b_comment_client_id = (b_questions[0].get("comment_client_id") or "").lower()
    b_comments = env.linear.comments(b_card["issue_id"])
    b_question_comment = next((c for c in b_comments if c["id"].lower() == b_comment_client_id), None)
    checks.require(b_question_comment is not None, "(b) the question's board comment is found")
    env.operator_client.reply(b_card["issue_id"], b_question_comment["id"], "Please proceed with the fixture.")

    n2 = night(2)
    returncode, output, log_path = env.yh.run_act(slug_b, "author", project_id, night=n2, label="b-n2-author")
    checks.require(returncode == 0, f"(b) N2 author exits 0 (got {returncode}); see {log_path}")

    snap_b2 = env.snapshot(slug_b, project_id, "b-after-n2-author")
    n2_id = snap_b2.night_id(n2)
    banked_events = [e for e in snap_b2.events(type="WaitingOnYouReplyBanked") if e["night_id"] == n2_id]
    checks.expect(len(banked_events) >= 1, "(b) WaitingOnYouReplyBanked recorded in N2")
    banked_rows = snap_b2.rows("SELECT * FROM banked_reply WHERE card_id = ?", (b_card["id"],))
    checks.expect(
        any(row["night_id"] == n2_id for row in banked_rows), "(b) a banked_reply row whose night_id is N2's"
    )
    mainline_rows = []
    for row in banked_rows:
        mainline_rows += snap_b2.rows(
            "SELECT * FROM banked_reply_mainline WHERE banked_reply_id = ? AND repository = ?",
            (row["id"], "fixture-backend"),
        )
    checks.expect(
        any(re.fullmatch(r"[0-9a-f]{40}", row["mainline_commit"] or "") for row in mainline_rows),
        f"(b) a banked_reply_mainline row for fixture-backend with a 40-hex commit (found {mainline_rows})",
    )
    b_comments_after = env.linear.comments(b_card["issue_id"])
    checks.expect(
        any(
            c["body"].startswith("**Nothing runs; it is recorded and travels with the Card into Adoption.**")
            for c in b_comments_after
        ),
        "(b) an app comment acknowledges with 'Nothing runs; it is recorded...'",
    )
    b_card_after = next(c for c in snap_b2.cards() if c["id"] == b_card["id"])
    checks.expect(
        b_card_after["state"] == "Waiting on You", f"(b) the Card stays Waiting on You (got {b_card_after['state']!r})"
    )
    checks.expect(
        not any(e["night_id"] == n2_id for e in snap_b2.events(type="CardUnansweredBoundFired")),
        "(b) no CardUnansweredBoundFired",
    )

    env.yh.run_act(slug_b, "build", project_id, night=n2, label="b-n2-build")
    returncode, output, log_path = env.yh.run_act(slug_b, "land", project_id, night=n2, label="b-n2-land")
    checks.expect(returncode == 0, f"(b) N2 land exits 0 (got {returncode}); see {log_path}")


# MARK: - 6. `unanswered_nights_max` firing with a value of 1


@scenario(6, "`unanswered_nights_max` firing with a value of 1")
def scenario_6(env, checks):
    project_id = "rehearsal-suite-a"
    slug = "06-unanswered-nights-max"

    manifest = suite_env.reset_project(env, project_id)
    suite_env.write_scenario_project_file(env, project_id, manifest, limits={"unanswered_nights_max": 1})

    n1 = night(1)
    returncode, output, log_path = env.yh.run_rehearse(
        slug, project_id, night=n1, result_fixtures=[("worker", "worker-question")]
    )
    checks.require(returncode == 0, f"N1 rehearse exits 0 (got {returncode}); see {log_path}")

    snap1 = env.snapshot(slug, project_id, "after-n1")
    cards = snap1.cards()
    checks.require(len(cards) == 1, f"exactly one Card (found {len(cards)})")
    card = cards[0]
    checks.expect(card["state"] == "Waiting on You", f"the Card is Waiting on You (got {card['state']!r})")
    checks.expect(len(snap1.events(type="CycleLanded")) >= 1, "N1: CycleLanded recorded")

    features = snap1.features()
    checks.require(len(features) == 1, "exactly one Feature recorded")
    held = _held_worktrees_for(snap1, features[0]["issue_id"])
    backend_worktree = next((w for w in held if w["repository"] == "fixture-backend"), None)
    checks.require(backend_worktree is not None, "a held fixture-backend Worktree exists")
    suite_env.stand_in_commit(backend_worktree["path"], "n1-fixture-backend")

    n2 = night(2)
    returncode, output, log_path = env.yh.run_rehearse(slug, project_id, night=n2, label="n2-rehearse")
    checks.expect(returncode == 0, f"N2 rehearse exits 0 (got {returncode}); see {log_path}")

    snap2 = env.snapshot(slug, project_id, "after-n2")
    n2_id = snap2.night_id(n2)
    checks.expect(
        not any(e["night_id"] == n2_id for e in snap2.events(type="CardUnansweredBoundFired")),
        "N2: no CardUnansweredBoundFired",
    )
    card2 = next(c for c in snap2.cards() if c["id"] == card["id"])
    checks.expect(card2["state"] == "Waiting on You", f"N2: the Card is still Waiting on You (got {card2['state']!r})")
    checks.expect(True, f"N2: card.unanswered_nights = {card2.get('unanswered_nights')}")

    n3 = night(3)
    returncode, output, log_path = env.yh.run_rehearse(slug, project_id, night=n3, label="n3-rehearse")
    checks.expect(returncode == 0, f"N3 rehearse exits 0 (got {returncode}); see {log_path}")

    snap3 = env.snapshot(slug, project_id, "after-n3")
    n3_id = snap3.night_id(n3)
    fired = [e for e in snap3.events(type="CardUnansweredBoundFired") if e["night_id"] == n3_id]
    checks.require(len(fired) >= 1, "N3: CardUnansweredBoundFired recorded")
    checks.expect(
        fired[0]["payload"].get("bound") == "1" and fired[0]["payload"].get("block_reason") == "unanswered",
        f"N3: bound 1, block_reason unanswered (got {fired[0]['payload']})",
    )
    card3 = next(c for c in snap3.cards() if c["id"] == card["id"])
    checks.expect(
        card3["state"] == "Blocked" and card3.get("block_reason") == "unanswered",
        f"N3: the Card is Blocked / unanswered (got state={card3['state']!r} block_reason={card3.get('block_reason')!r})",
    )
    board_card = env.linear.issue(card["issue_id"])
    checks.expect(board_card["state"]["name"] == "Blocked", f"N3: board state is Blocked (got {board_card['state']})")
    label_names = {label["name"] for label in board_card.get("labels", {}).get("nodes", [])}
    checks.expect("unanswered" in label_names, f"N3: label 'unanswered' present (got {label_names})")
    operator_id = suite_env.read_operator_identity(
        env.configuration_directory, suite_env.resolve_installation(env).name
    )
    assignee = board_card.get("assignee") or {}
    checks.expect(
        operator_id is not None and assignee.get("id") == operator_id,
        f"N3: assignee is the installation's operator (got {assignee}, expected {operator_id})",
    )


# MARK: - Scenarios 7-13 (scenarios_recovery.py registers into SCENARIOS above)

import scenarios_recovery  # noqa: E402,F401

