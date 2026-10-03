"""
Scenarios 7-13 of the rehearsal scenario suite (P15.3, slice C): recovery, adoption, concurrency
and configuration-conflict scenarios. Split out of `scenarios.py` to keep both modules under
~900 lines; `scenarios.py` imports this module at the bottom so `import scenarios` alone
populates the whole registry.
"""

import json
import os
import signal
from datetime import datetime, timezone
from pathlib import Path

from scenarios import LAND_FINISHED, _cards_of_repository, night, scenario, suite_env


# MARK: - 7. Engine invocation killed mid-Card, then reclaimed


@scenario(7, "Engine invocation killed mid-Card, then reclaimed")
def scenario_7(env, checks):
    project_id = "rehearsal-suite-a"
    slug = "07-killed-mid-card-reclaim"

    hold_dir = (env.work_directory / slug / "hold").resolve()
    hold_dir.mkdir(parents=True, exist_ok=True)
    hold_marker = hold_dir / "HOLD"
    started_marker = hold_dir / "STARTED"

    manifest = suite_env.reset_project(env, project_id)
    suite_env.write_scenario_project_file(
        env, project_id, manifest,
        repo_overrides={
            "fixture-backend": {
                "check": suite_env.hold_check_command(hold_dir), "check_literal": True,
            },
        },
    )

    try:
        n1 = night(1)
        returncode, output, log_path = env.yh.run_act(slug, "author", project_id, night=n1)
        checks.require(returncode == 0, f"author exits 0 (got {returncode}); see {log_path}")

        hold_marker.write_text("hold\n")

        process, build_log_path, handle = env.yh.start_act(slug, "build", project_id, night=n1)
        try:
            started = suite_env.wait_for_file(
                started_marker, timeout=300.0, still_running=lambda: process.poll() is None
            )
            checks.require(
                started, f"the held build Act started (STARTED marker appeared) before exiting; see {build_log_path}"
            )
            os.kill(process.pid, signal.SIGKILL)
            process.wait(timeout=30)
        finally:
            handle.close()
        checks.expect(
            process.returncode == -signal.SIGKILL, f"the build Act was SIGKILLed (got returncode {process.returncode})"
        )

        snap_killed = env.snapshot(slug, project_id, "after-kill")
        n1_id = snap_killed.night_id(n1)
        act_started = [
            e for e in snap_killed.events(type="ActStarted") if e["night_id"] == n1_id and e["act"] == "build"
        ]
        checks.require(len(act_started) >= 1, "an ActStarted event exists for the killed build Act")
        killed_run_id = act_started[-1]["run_id"]

        cards = snap_killed.cards()
        checks.require(len(cards) == 1, f"exactly one Card (found {len(cards)})")
        card = cards[0]
        checks.expect(card["state"] == "In Progress", f"the Card is In Progress (got {card['state']!r})")

        attempts = snap_killed.rows("SELECT * FROM attempt WHERE card_id = ?", (card["id"],))
        open_attempts = [a for a in attempts if a.get("ended_at") is None]
        checks.expect(len(open_attempts) == 1, f"one attempt row with ended_at NULL (found {open_attempts})")

        card_lease_rows = snap_killed.rows("SELECT * FROM lease WHERE card_id = ?", (card["id"],))
        checks.require(len(card_lease_rows) == 1, "a lease row for the Card")
        checks.expect(
            card_lease_rows[0]["run_id"] == killed_run_id,
            f"the Card lease's run_id is the killed run (got {card_lease_rows[0]['run_id']!r})",
        )
        act_lease_rows = snap_killed.rows("SELECT * FROM act_lease WHERE id = 1")
        checks.require(len(act_lease_rows) == 1, "an act_lease row")
        checks.expect(
            act_lease_rows[0]["run_id"] == killed_run_id,
            f"the act_lease's run_id is the killed run (got {act_lease_rows[0]['run_id']!r})",
        )
        now = datetime.now(timezone.utc)
        checks.expect(
            suite_env.scratch_linear.parse_journal_timestamp(act_lease_rows[0]["expires_at"]) > now,
            f"act_lease.expires_at is ahead of now (got {act_lease_rows[0]['expires_at']!r})",
        )
        checks.expect(
            suite_env.scratch_linear.parse_journal_timestamp(card_lease_rows[0]["expires_at"]) > now,
            f"the Card lease's expires_at is ahead of now (got {card_lease_rows[0]['expires_at']!r})",
        )

        def still_active():
            snap = env.snapshot(slug, project_id, "poll-expiry")
            try:
                rows = (
                    snap.rows("SELECT expires_at FROM act_lease WHERE id = 1")
                    + snap.rows("SELECT expires_at FROM lease WHERE card_id = ?", (card["id"],))
                )
            finally:
                snap.close()
            now = datetime.now(timezone.utc)
            return {
                row["expires_at"] for row in rows
                if suite_env.scratch_linear.parse_journal_timestamp(row["expires_at"]) > now
            }

        suite_env.wait_until_all_expired(
            still_active, on_tick=lambda minute: print(f"[7] waiting for the killed run's Leases to expire: minute {minute}")
        )

        returncode, output, log_path = env.yh.run_act(slug, "build", project_id, night=n1, label="build-reclaim")
        checks.require(returncode == 0, f"the reclaiming build exits 0 (got {returncode}); see {log_path}")

        snap_reclaimed = env.snapshot(slug, project_id, "after-reclaim")
        lease_reclaimed = [
            e for e in snap_reclaimed.events(type="LeaseReclaimed")
            if e["payload"].get("previous_run_id") == killed_run_id
        ]
        checks.expect(len(lease_reclaimed) >= 1, "LeaseReclaimed names the killed run")
        card_lease_reclaimed = [
            e for e in snap_reclaimed.events(type="CardLeaseReclaimed")
            if e["payload"].get("previous_run_id") == killed_run_id
        ]
        checks.expect(len(card_lease_reclaimed) >= 1, "CardLeaseReclaimed recorded")
        card_reclaimed_events = [
            e for e in snap_reclaimed.events(type="CardReclaimed")
            if e["payload"].get("card_id") == str(card["id"])
        ]
        checks.expect(len(card_reclaimed_events) >= 1, "CardReclaimed recorded for the Card")

        attempts_after = snap_reclaimed.rows("SELECT * FROM attempt WHERE card_id = ?", (card["id"],))
        killed_attempt = next((a for a in attempts_after if a["id"] == open_attempts[0]["id"]), None)
        checks.require(killed_attempt is not None, "the killed attempt row still exists")
        checks.expect(
            killed_attempt.get("result") == "Crashed-Unknown",
            f"the killed attempt ended Crashed-Unknown (got {killed_attempt.get('result')!r})",
        )
        checks.expect(
            "route not excluded" in (killed_attempt.get("consumed_how") or ""),
            f"consumed_how names 'route not excluded' (got {killed_attempt.get('consumed_how')!r})",
        )
        route_exclusions = snap_reclaimed.rows("SELECT * FROM route_exclusion WHERE card_id = ?", (card["id"],))
        checks.expect(not route_exclusions, f"no route_exclusion row for the Card (found {route_exclusions})")

        other_attempts = [a for a in attempts_after if a["id"] != killed_attempt["id"]]
        checks.expect(
            any(a.get("result") == "success" for a in other_attempts),
            f"a second attempt row ending success (found {other_attempts})",
        )
        card_after = next(c for c in snap_reclaimed.cards() if c["id"] == card["id"])
        checks.expect(card_after["state"] == "Done", f"the Card is Done (got {card_after['state']!r})")

        returncode, output, log_path = env.yh.run_act(slug, "land", project_id, night=n1)
        checks.require(returncode == 0, f"land exits 0 (got {returncode}); see {log_path}")
        snap_land = env.snapshot(slug, project_id, "after-land")
        checks.expect(len(snap_land.events(type="CycleLanded")) >= 1, "CycleLanded recorded")
    finally:
        leftover = suite_env.find_processes_with_command_line("sleep 3600")
        if leftover:
            killed = suite_env.kill_leftover_processes(leftover)
            checks.expect(False, f"leftover 'sleep 3600' process(es) had to be killed: {killed}")


# MARK: - 8. Outbox replay after a killed run


@scenario(8, "Outbox replay after a killed run")
def scenario_8(env, checks):
    project_id = "rehearsal-suite-a"
    slug = "08-outbox-replay"

    manifest = suite_env.reset_project(env, project_id)
    suite_env.write_scenario_project_file(env, project_id, manifest)

    n1 = night(1)
    returncode, output, log_path = env.yh.run_act(
        slug, "author", project_id, night=n1,
        extra_env={"YH_REHEARSAL_OUTBOX_KILL": "group:1"}, retry=False,
    )
    checks.require(
        suite_env.is_killed_by_sigkill(returncode),
        f"author died by SIGKILL (got returncode {returncode}); see {log_path}",
    )

    snap_killed = env.snapshot(slug, project_id, "after-kill")
    group_rows = snap_killed.rows("SELECT * FROM outbox WHERE group_id IS NOT NULL ORDER BY id")
    checks.require(bool(group_rows), "at least one grouped outbox entry recorded")
    checks.expect(
        all(row["state"] == "pending" for row in group_rows), f"every grouped entry is pending (found {group_rows})"
    )
    client_ids = [row["client_id"] for row in group_rows]

    first_issue = env.linear.issue(group_rows[0]["client_id"].lower())
    checks.expect(first_issue is not None, "the first group entry's board object exists")
    for later in group_rows[1:]:
        later_issue = env.linear.issue(later["client_id"].lower())
        checks.expect(later_issue is None, f"group entry {later['client_id']} does not exist on the board yet")

    def still_active():
        snap = env.snapshot(slug, project_id, "poll-expiry")
        try:
            rows = snap.rows("SELECT expires_at FROM act_lease WHERE id = 1")
        finally:
            snap.close()
        now = datetime.now(timezone.utc)
        return {
            row["expires_at"] for row in rows
            if suite_env.scratch_linear.parse_journal_timestamp(row["expires_at"]) > now
        }

    suite_env.wait_until_all_expired(
        still_active, on_tick=lambda minute: print(f"[8] waiting for the Act lease to expire: minute {minute}")
    )

    returncode, output, log_path = env.yh.run_act(slug, "author", project_id, night=n1, label="author-replay")
    checks.require(returncode == 0, f"the replaying author exits 0 (got {returncode}); see {log_path}")

    snap_replayed = env.snapshot(slug, project_id, "after-replay")
    checks.expect(len(snap_replayed.events(type="LeaseReclaimed")) >= 1, "LeaseReclaimed recorded")

    placeholders = ",".join("?" * len(client_ids))
    replayed_rows = {
        row["client_id"]: row
        for row in snap_replayed.rows(f"SELECT * FROM outbox WHERE client_id IN ({placeholders})", tuple(client_ids))
    }
    all_applied = all(
        replayed_rows.get(client_id) is not None
        and replayed_rows[client_id]["state"] == "applied"
        and replayed_rows[client_id]["result"] == client_id
        for client_id in client_ids
    )
    checks.expect(all_applied, f"every group entry is applied with result == client_id (found {replayed_rows})")
    checks.expect(len(snap_replayed.events(type="FeatureAuthored")) >= 1, "FeatureAuthored recorded")

    linear_project_id = suite_env.read_linear_project(env.configuration_directory, project_id)
    all_ids = env.linear.project_issue_ids(linear_project_id)
    titles_seen = {}
    for issue_id in all_ids:
        issue = env.linear.issue(issue_id)
        if issue:
            titles_seen.setdefault(issue["title"], []).append(issue_id)
    for client_id in client_ids:
        row = replayed_rows.get(client_id)
        if not row or row.get("operation") != "issueCreate":
            continue
        title = suite_env.created_issue_title(row["payload"])
        if not checks.expect(title is not None, f"the group's issueCreate {client_id} names its title"):
            continue
        matching = titles_seen.get(title, [])
        checks.expect(len(matching) == 1, f"exactly one issue titled {title!r} exists (found {matching})")

    env.yh.run_act(slug, "build", project_id, night=n1)
    returncode, output, log_path = env.yh.run_act(slug, "land", project_id, night=n1)
    checks.require(returncode == 0, f"land exits 0 (got {returncode}); see {log_path}")
    snap_land = env.snapshot(slug, project_id, "after-land")
    checks.expect(len(snap_land.events(type="CycleLanded")) >= 1, "CycleLanded recorded")


# MARK: - 9. Protected Path refusal


@scenario(9, "Protected Path refusal", needs_operator=True)
def scenario_9(env, checks):
    project_id = "rehearsal-suite-a"
    slug = "09-protected-path-refusal"

    manifest = suite_env.reset_project(env, project_id)
    suite_env.write_scenario_project_file(env, project_id, manifest)

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
    checks.require(len(features) == 1, "exactly one Feature recorded")
    backend_cards = _cards_of_repository(snap_after_author, features[0]["id"], "fixture-backend")
    checks.require(len(backend_cards) >= 1, "at least one fixture-backend Card")
    p_card = backend_cards[0]

    env.operator_client.declare_scope(p_card["issue_id"], "**Scope:** `migrations/0002_fixture.sql`")

    returncode, output, log_path = env.yh.run_act(slug, "build", project_id, night=n1)
    checks.require(returncode == 0, f"build exits 0 (got {returncode}); see {log_path}")

    snap_after_build = env.snapshot(slug, project_id, "after-build")
    refused = [
        e for e in snap_after_build.events(type="ProtectedPathRefused")
        if e["payload"].get("issue_id") == p_card["issue_id"]
    ]
    checks.require(len(refused) >= 1, "ProtectedPathRefused recorded for P")
    checks.expect(
        refused[0]["payload"].get("declared_path") == "migrations/0002_fixture.sql",
        f"declared_path is migrations/0002_fixture.sql (got {refused[0]['payload'].get('declared_path')!r})",
    )
    checks.expect(
        refused[0]["payload"].get("protected_path") == "migrations/",
        f"protected_path is migrations/ (got {refused[0]['payload'].get('protected_path')!r})",
    )

    p_after = next(c for c in snap_after_build.cards() if c["id"] == p_card["id"])
    checks.expect(p_after["state"] == "Waiting on You", f"P is Waiting on You (got {p_after['state']!r})")
    attempts = snap_after_build.rows("SELECT * FROM attempt WHERE card_id = ?", (p_after["id"],))
    checks.expect(not attempts, f"no attempt row for P (found {attempts})")
    answered = [
        e for e in snap_after_build.events(type="RehearsalFixtureAnswered")
        if e["payload"].get("issue_id") == p_card["issue_id"]
    ]
    checks.expect(not answered, f"no RehearsalFixtureAnswered for P (found {answered})")

    # The lane that moved past P is the one in the refusal's own run. A build Act retried after a
    # transient Linear failure runs the lane again with P already Waiting on You, so skips nothing.
    lane_ended = [
        e for e in snap_after_build.events(type="RepoLaneEnded")
        if e["payload"].get("repository") == "fixture-backend" and e["run_id"] == refused[0]["run_id"]
    ]
    checks.require(len(lane_ended) >= 1, "RepoLaneEnded recorded for fixture-backend in the refusal's run")
    skipped = int(lane_ended[-1]["payload"].get("cards_skipped", "0"))
    checks.expect(skipped >= 1, f"RepoLaneEnded cards_skipped >= 1 in the refusal's run (got {skipped})")
    other_backend = [c for c in backend_cards if c["issue_id"] != p_card["issue_id"]]
    other_backend_after = [
        c for c in snap_after_build.cards() if c["issue_id"] in {c2["issue_id"] for c2 in other_backend}
    ]
    non_done = [c for c in other_backend_after if c["state"] != "Done"]
    checks.expect(not non_done, f"the other two backend Cards are Done (found non-Done: {non_done})")

    comments = env.linear.comments(p_card["issue_id"])
    checks.expect(
        any("not a sandbox" in c["body"] for c in comments),
        "an app comment on P names the Protected Paths limitation",
    )

    returncode, output, log_path = env.yh.run_act(slug, "land", project_id, night=n1)
    checks.expect(returncode == 0, f"land exits 0 (got {returncode}); see {log_path}")


# MARK: - 10. Divergence at dispatch; Adoption success and refusal


@scenario(10, "Divergence at dispatch; Adoption success and refusal")
def scenario_10(env, checks):
    project_id = "rehearsal-suite-a"
    slug = "10-divergence-and-adoption"

    manifest = suite_env.reset_project(env, project_id)
    # Default Bounds: B asks rather than fails, and an adopted Card resumes with the Attempt budget it
    # left with — asking spent none of it.
    suite_env.write_scenario_project_file(env, project_id, manifest)

    n1 = night(1)
    returncode, output, log_path = env.yh.run_act(
        slug, "author", project_id, night=n1,
        result_fixtures=[
            ("selection", "selection-selected-with-contract"),
            ("breakdown", "breakdown-drafted-with-contract"),
        ],
    )
    checks.require(returncode == 0, f"author exits 0 (got {returncode}); see {log_path}")

    snap_after_author = env.snapshot(slug, project_id, "after-author")
    backend_cards = [c for c in snap_after_author.cards() if c["repository"] == "fixture-backend"]
    web_cards = [c for c in snap_after_author.cards() if c["repository"] == "fixture-web"]
    checks.require(len(backend_cards) == 1, f"exactly one backend Card (found {len(backend_cards)})")
    checks.require(len(web_cards) == 1, f"exactly one web Card (found {len(web_cards)})")
    b_card, w_card = backend_cards[0], web_cards[0]

    suite_env.apply_fixture(env.root, project_id, "transcription-path-touched")

    returncode, output, log_path = env.yh.run_act(
        slug, "build", project_id, night=n1, result_fixtures=[("worker", b_card["issue_id"], "worker-question")]
    )
    checks.require(returncode == 0, f"build exits 0 (got {returncode}); see {log_path}")

    snap_after_build = env.snapshot(slug, project_id, "after-build")
    b_after = next(c for c in snap_after_build.cards() if c["id"] == b_card["id"])
    checks.expect(
        b_after["state"] == "Waiting on You" and b_after.get("waiting_reason") == "question",
        f"B is Waiting on You / question (got state={b_after['state']!r} waiting_reason={b_after.get('waiting_reason')!r})",
    )

    diverged = [
        e for e in snap_after_build.events(type="CardDiverged") if e["payload"].get("issue_id") == w_card["issue_id"]
    ]
    checks.require(len(diverged) >= 1, "CardDiverged recorded for W")
    checks.expect(
        diverged[0]["payload"].get("repository") == "fixture-backend",
        f"CardDiverged names fixture-backend (got {diverged[0]['payload']})",
    )
    changed_paths = set(diverged[0]["payload"].get("changed_paths", "").split("\u001f"))
    checks.expect(
        "contracts/fixture-api.json" in changed_paths,
        f"CardDiverged names the touched contract path (got {changed_paths})",
    )
    w_after = next(c for c in snap_after_build.cards() if c["id"] == w_card["id"])
    checks.expect(
        w_after["state"] == "Waiting on You" and w_after.get("waiting_reason") == "divergence",
        f"W is Waiting on You / divergence (got state={w_after['state']!r} waiting_reason={w_after.get('waiting_reason')!r})",
    )
    checks.expect(
        w_after.get("consecutive_divergences") == 1,
        f"W's consecutive_divergences is 1 (got {w_after.get('consecutive_divergences')})",
    )
    w_attempts = snap_after_build.rows("SELECT * FROM attempt WHERE card_id = ?", (w_after["id"],))
    checks.expect(not w_attempts, f"no attempt row for W (found {w_attempts})")

    returncode, output, log_path = env.yh.run_act(slug, "land", project_id, night=n1)
    checks.require(returncode == 0, f"land exits 0 (got {returncode}); see {log_path}")
    snap_after_land1 = env.snapshot(slug, project_id, "after-land-n1")
    checks.expect(len(snap_after_land1.events(type="CycleLanded")) >= 1, "N1: CycleLanded recorded")
    f1_row = snap_after_land1.features()[0]
    cycle_rows = snap_after_land1.rows("SELECT * FROM cycle WHERE feature_id = ?", (f1_row["id"],))
    checks.require(len(cycle_rows) == 1, "N1: exactly one cycle row")
    checks.expect(cycle_rows[0]["archived_at"] is None, "N1: the Cycle is not archived")

    n2 = night(2)
    returncode, output, log_path = env.yh.run_act(
        slug, "author", project_id, night=n2, feature="Fixture Feature 2",
        result_fixtures=[
            ("selection", "selection-selected-adopting"),
            ("breakdown", "breakdown-drafted-with-contract"),
        ],
        label="n2-author",
    )
    checks.require(returncode == 0, f"N2 author exits 0 (got {returncode}); see {log_path}")

    snap_after_n2_author = env.snapshot(slug, project_id, "after-n2-author")
    closed_by_merge = [
        e for e in snap_after_n2_author.events(type="FeatureClosedByMerge")
        if e["payload"].get("feature_issue_id") == f1_row["issue_id"]
    ]
    checks.expect(len(closed_by_merge) >= 1, "FeatureClosedByMerge recorded for Feature 1")
    b_blocked_by_closure = [
        e for e in snap_after_n2_author.events(type="CardStateTransitioned")
        if e["payload"].get("issue_id") == b_card["issue_id"] and e["payload"].get("to_state") == "Blocked"
    ]
    checks.expect(
        len(b_blocked_by_closure) >= 1, "the merge closure auto-Blocked B, carrying it forward for Adoption"
    )

    adopted = [
        e for e in snap_after_n2_author.events(type="CardAdopted") if e["payload"].get("issue_id") == b_card["issue_id"]
    ]
    checks.require(len(adopted) >= 1, "CardAdopted recorded for B")
    b_after_adoption = next(c for c in snap_after_n2_author.cards() if c["id"] == b_card["id"])
    f2_row = next(f for f in snap_after_n2_author.features() if f["issue_id"] != f1_row["issue_id"])
    f2_cycle = snap_after_n2_author.rows("SELECT * FROM cycle WHERE feature_id = ?", (f2_row["id"],))[0]
    checks.expect(
        b_after_adoption["cycle_id"] == f2_cycle["id"],
        f"B's cycle_id is Feature 2's cycle (got {b_after_adoption['cycle_id']}, expected {f2_cycle['id']})",
    )

    refused = [
        e for e in snap_after_n2_author.events(type="AdoptionRefused") if e["payload"].get("issue_id") == w_card["issue_id"]
    ]
    checks.require(len(refused) >= 1, "AdoptionRefused recorded for W")
    refusal_rows = snap_after_n2_author.rows("SELECT * FROM adoption_refusal WHERE card_id = ?", (w_after["id"],))
    stale_paths = {
        path
        for row in refusal_rows
        for block in json.loads(row.get("stale_blocks") or "[]")
        for path in block.get("changedPaths", [])
    }
    checks.expect(
        "contracts/fixture-api.json" in stale_paths,
        f"an adoption_refusal row names the stale contract path (found {stale_paths})",
    )
    w_after_refusal = next(c for c in snap_after_n2_author.cards() if c["id"] == w_card["id"])
    checks.expect(
        w_after_refusal["state"] == "Waiting on You" and w_after_refusal.get("waiting_reason") == "divergence",
        f"W stays Waiting on You / divergence (got {w_after_refusal})",
    )
    checks.expect(
        w_after_refusal.get("failed_adoptions") == 1,
        f"W's failed_adoptions is 1 (got {w_after_refusal.get('failed_adoptions')})",
    )

    returncode, output, log_path = env.yh.run_act(slug, "build", project_id, night=n2, label="n2-build")
    checks.require(returncode == 0, f"N2 build exits 0 (got {returncode}); see {log_path}")
    snap_after_n2_build = env.snapshot(slug, project_id, "after-n2-build")
    b_after_build = next(c for c in snap_after_n2_build.cards() if c["id"] == b_card["id"])
    checks.expect(b_after_build["state"] == "Done", f"B is Done (got {b_after_build['state']!r})")

    returncode, output, log_path = env.yh.run_act(slug, "land", project_id, night=n2, label="n2-land")
    checks.expect(returncode == 0, f"N2 land exits 0 (got {returncode}); see {log_path}")


# MARK: - 11. Cancelled Card and reopen


@scenario(11, "Cancelled Card and reopen", needs_operator=True)
def scenario_11(env, checks):
    project_id = "rehearsal-suite-a"
    slug = "11-cancelled-card-and-reopen"

    manifest = suite_env.reset_project(env, project_id)
    suite_env.write_scenario_project_file(env, project_id, manifest)

    n1 = night(1)
    returncode, output, log_path = env.yh.run_act(
        slug, "author", project_id, night=n1,
        result_fixtures=[
            ("selection", "selection-selected-with-contract"),
            ("breakdown", "breakdown-drafted-with-contract"),
        ],
    )
    checks.require(returncode == 0, f"author exits 0 (got {returncode}); see {log_path}")

    snap_after_author = env.snapshot(slug, project_id, "after-author")
    web_cards = [c for c in snap_after_author.cards() if c["repository"] == "fixture-web"]
    checks.require(len(web_cards) == 1, f"exactly one fixture-web Card (found {len(web_cards)})")
    w_card = web_cards[0]
    backend_cards = [c for c in snap_after_author.cards() if c["repository"] == "fixture-backend"]
    checks.require(len(backend_cards) >= 1, "at least one fixture-backend Card")

    env.operator_client.move_to_state_of_type(w_card["issue_id"], "canceled")

    returncode, output, log_path = env.yh.run_act(slug, "build", project_id, night=n1, label="build-1")
    checks.require(returncode == 0, f"build exits 0 (got {returncode}); see {log_path}")

    snap_after_build1 = env.snapshot(slug, project_id, "after-build-1")
    cancelled = [
        e for e in snap_after_build1.events(type="CardCancelled") if e["payload"].get("issue_id") == w_card["issue_id"]
    ]
    checks.require(len(cancelled) >= 1, "CardCancelled recorded for W")
    checks.expect(
        cancelled[0]["payload"].get("previous_state") == "Todo",
        f"previous_state is Todo (got {cancelled[0]['payload'].get('previous_state')!r})",
    )
    w_after_cancel = next(c for c in snap_after_build1.cards() if c["id"] == w_card["id"])
    checks.expect(
        w_after_cancel["state"] == "Cancelled" and w_after_cancel.get("cancelled_from_state") == "Todo",
        f"W is Cancelled with cancelled_from_state Todo (got {w_after_cancel})",
    )
    w_attempts = snap_after_build1.rows("SELECT * FROM attempt WHERE card_id = ?", (w_after_cancel["id"],))
    checks.expect(not w_attempts, f"no attempt for W (found {w_attempts})")
    backend_after = [
        c for c in snap_after_build1.cards() if c["issue_id"] in {c2["issue_id"] for c2 in backend_cards}
    ]
    non_done_backend = [c for c in backend_after if c["state"] != "Done"]
    checks.expect(not non_done_backend, f"the backend Card is Done (found non-Done: {non_done_backend})")

    env.operator_client.move_to_state(w_card["issue_id"], "Todo")

    returncode, output, log_path = env.yh.run_act(slug, "build", project_id, night=n1, label="build-2")
    checks.require(returncode == 0, f"second build exits 0 (got {returncode}); see {log_path}")

    snap_after_build2 = env.snapshot(slug, project_id, "after-build-2")
    reopened = [
        e for e in snap_after_build2.events(type="CardReopened") if e["payload"].get("issue_id") == w_card["issue_id"]
    ]
    checks.require(len(reopened) >= 1, "CardReopened recorded for W")
    checks.expect(
        reopened[0]["payload"].get("restored_state") == "Todo",
        f"restored_state is Todo (got {reopened[0]['payload'].get('restored_state')!r})",
    )
    w_after_reopen = next(c for c in snap_after_build2.cards() if c["id"] == w_card["id"])
    checks.expect(w_after_reopen["state"] == "Done", f"W is Done (got {w_after_reopen['state']!r})")

    returncode, output, log_path = env.yh.run_act(slug, "land", project_id, night=n1)
    checks.require(returncode == 0, f"land exits 0 (got {returncode}); see {log_path}")

    snap_after_land = env.snapshot(slug, project_id, "after-land")
    checks.expect(len(snap_after_land.events(type="CycleLanded")) >= 1, "CycleLanded recorded")
    features = snap_after_land.features()
    checks.require(len(features) == 1, "exactly one Feature recorded")
    cycle_rows = snap_after_land.rows("SELECT * FROM cycle WHERE feature_id = ?", (features[0]["id"],))
    checks.require(len(cycle_rows) == 1, "exactly one cycle row")
    checks.expect(cycle_rows[0]["archived_at"] is not None, "the Cycle is archived")


# MARK: - 12. Two Projects concurrently on one Mac sharing the scratch team


@scenario(12, "Two Projects concurrently on one Mac sharing the scratch team")
def scenario_12(env, checks):
    slug = "12-two-projects-concurrently"
    project_a, project_b = "rehearsal-suite-a", "rehearsal-suite-b"

    manifest_a = suite_env.reset_project(env, project_a)
    suite_env.write_scenario_project_file(env, project_a, manifest_a)
    manifest_b = suite_env.reset_project(env, project_b)
    suite_env.write_scenario_project_file(env, project_b, manifest_b)

    n1 = night(1)
    fixtures = [
        ("selection", "selection-selected-with-contract"),
        ("breakdown", "breakdown-drafted-with-contract"),
    ]
    process_a, log_a, handle_a = env.yh.start_rehearse(slug, project_a, night=n1, result_fixtures=fixtures, label="a-rehearse")
    process_b, log_b, handle_b = env.yh.start_rehearse(slug, project_b, night=n1, result_fixtures=fixtures, label="b-rehearse")
    try:
        returncode_a = process_a.wait(timeout=env.yh.act_timeout)
        returncode_b = process_b.wait(timeout=env.yh.act_timeout)
    finally:
        handle_a.close()
        handle_b.close()

    output_a = Path(log_a).read_text()
    output_b = Path(log_b).read_text()
    checks.require(returncode_a == 0, f"Project A rehearse exits 0 (got {returncode_a}); see {log_a}")
    checks.require(returncode_b == 0, f"Project B rehearse exits 0 (got {returncode_b}); see {log_b}")
    checks.expect(LAND_FINISHED in output_a, "Project A output names the land Act finished")
    checks.expect(LAND_FINISHED in output_b, "Project B output names the land Act finished")

    snap_a = env.snapshot(slug, project_a, "a-after-rehearse")
    snap_b = env.snapshot(slug, project_b, "b-after-rehearse")

    for label, snap, other_label, other_snap, project_id, other_project_id in (
        ("A", snap_a, "B", snap_b, project_a, project_b),
        ("B", snap_b, "A", snap_a, project_b, project_a),
    ):
        project_ids = {row["project_id"] for row in snap.rows("SELECT DISTINCT project_id FROM night")}
        checks.expect(
            project_ids == {project_id}, f"{label}: night.project_id is exactly {{{project_id}}} (got {project_ids})"
        )

        own_ids = suite_env.journal_issue_ids(snap)
        other_ids = suite_env.journal_issue_ids(other_snap)
        linear_project_id = suite_env.read_linear_project(env.configuration_directory, project_id)
        other_linear_project_id = suite_env.read_linear_project(env.configuration_directory, other_project_id)
        board_ids = set(env.linear.project_issue_ids(linear_project_id))
        other_board_ids = set(env.linear.project_issue_ids(other_linear_project_id))

        checks.expect(
            own_ids <= board_ids,
            f"{label}: every Journal issue id is in {project_id}'s Linear project (missing {own_ids - board_ids})",
        )
        checks.expect(
            not (own_ids & other_ids), f"{label}: no issue id is shared with {other_label}'s Journal (shared {own_ids & other_ids})"
        )
        checks.expect(
            not (own_ids & other_board_ids),
            f"{label}: no issue id is in {other_label}'s Linear project (found {own_ids & other_board_ids})",
        )

        own_run_ids = suite_env.journal_run_ids(snap)
        other_run_ids = suite_env.journal_run_ids(other_snap)
        checks.expect(
            not (own_run_ids & other_run_ids), f"{label}: no run id shared with {other_label} (shared {own_run_ids & other_run_ids})"
        )

        expected_repo_root = (env.root / project_id / "repos").resolve()
        for worktree in snap.worktrees():
            common_dir = suite_env.worktree_git_common_dir(worktree["path"])
            checks.expect(
                common_dir is not None and Path(common_dir).resolve().is_relative_to(expected_repo_root),
                f"{label}: Worktree {worktree['path']}'s common dir ({common_dir}) is under {expected_repo_root}",
            )


# MARK: - 13. Two conflicting Projects plus one valid Project


@scenario(13, "Two conflicting Projects plus one valid Project")
def scenario_13(env, checks):
    project_id = "rehearsal-suite-a"
    slug = "13-conflicting-projects"
    conflict_a = "rehearsal-suite-conflict-1"
    conflict_b = "rehearsal-suite-conflict-2"

    manifest = suite_env.reset_project(env, project_id)
    suite_env.write_scenario_project_file(env, project_id, manifest)

    conflict_root = env.root / "conflict"
    conflict_manifest = suite_env.build_fixture_tree(conflict_root, "shared", force=True)
    shared_repo = conflict_manifest["repos"][0]

    conflict_paths = []
    try:
        for conflict_id in (conflict_a, conflict_b):
            text = suite_env.render_project_toml(
                project_id=conflict_id,
                name=conflict_id,
                installation=suite_env.resolve_installation(env).name,
                linear_project="00000000-0000-4000-8000-000000000000",
                spec_source=conflict_manifest["spec_source"],
                repos=[{
                    "name": shared_repo["name"], "path": shared_repo["path"], "role": shared_repo["role"],
                }],
            )
            path = suite_env.write_project_file(env.configuration_directory, conflict_id, text)
            conflict_paths.append(path)

        returncode, output, log_path = env.yh.run_validate(slug)
        checks.require(returncode == 1, f"yh validate exits 1 (got {returncode}); see {log_path}")
        for conflict_id in (conflict_a, conflict_b):
            checks.expect(
                any(
                    line.startswith("[FAIL]") and conflict_id in line and "also declared as a working Repo" in line
                    for line in output.splitlines()
                ),
                f"validate reports a [FAIL] naming {conflict_id!r} as also declared as a working Repo",
            )
        checks.expect(
            any(
                line.startswith("[pass]") and "rehearsal-suite-a" in line
                for line in output.splitlines()
            ),
            "validate reports a [pass] line for rehearsal-suite-a",
        )

        n1 = night(1)
        returncode, output, log_path = env.yh.run_rehearse(
            slug, project_id, night=n1,
            result_fixtures=[("selection", "selection-no-selectable-feature")],
        )
        checks.expect(
            returncode == 0, f"rehearse --project rehearsal-suite-a still exits 0 (got {returncode}); see {log_path}"
        )

        returncode, output, log_path = env.yh.run_act(
            slug, "author", conflict_a, night=night(1), label="author-conflict"
        )
        checks.expect(returncode == 1, f"author for {conflict_a} exits 1 (got {returncode})")
        checks.expect(
            "refused at load" in output, f"author output names 'refused at load' (see {log_path})"
        )
        conflict_journal = env.configuration_directory / "journals" / f"{conflict_a}.db"
        checks.expect(not conflict_journal.exists(), f"no Journal was created for {conflict_a}")
    finally:
        for path in conflict_paths:
            if path.exists():
                path.unlink()
