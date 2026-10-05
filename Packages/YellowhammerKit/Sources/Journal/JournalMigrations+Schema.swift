import Foundation
import GRDB

extension JournalMigrations {
    /// The Night: one row per Night of a Project, with its closing reason, verdict and board snapshot.
    static func createNightTable(_ db: Database) throws {
        try db.create(table: "night") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("project_id", .text).notNull()
            table.column("night_start", .text).notNull()
            table.column("mode", .text).notNull()
                .check(sql: "mode IN ('real','rehearsal')")
            table.column("state", .text).notNull()
            table.column("night_card_issue_id", .text)
            table.column("night_card_issue_id_for_display", .text)
            // The Night Card's Linear `identifier` and board `url`, recorded by the Delta Read so the
            // Pulse can open it (issue #230). Nullable: none until the Delta Read next sees the issue.
            table.column("night_card_issue_key", .text)
            table.column("night_card_issue_url", .text)
            table.column("opened_at", .text).notNull()
            table.column("completed_at", .text)
            // A Night closes with a reason, and the set is closed so the schema itself refuses one the
            // engine does not know. Nil until the Night is closed.
            table.column("close_reason", .text)
                .check(sql: "close_reason IN ('night_end','opened_and_died','project_removed')")
            // A Night's constant-time verdict line, as the Journal records it (OQ13). `idle` is the
            // only value written today; the schema itself refuses any other, exactly like `close_reason`.
            table.column("verdict", .text)
                .check(sql: "verdict IN ('idle')")
            // The Night whose morning a Partial Landing's merge closure concluded (roadmap P10.8; spec:
            // morning-report/triage-the-morning). Nullable, written at the Operator's settle (P10.9)
            // or on observing the merge (P10.8) — the one field a closed Night may still change.
            table.column("triaged_at", .text)
            // Nil means no observation; new observations are zero, nonzero or unknown.
            table.column("opening_ready_state", .text)
            table.column("closing_unanswered_max", .integer)
            table.column("closing_failed_adoptions_max", .integer)
            table.column("closing_author_supplied_citation_count", .integer)
            table.uniqueKey(["project_id", "night_start"])
        }
    }

    static func createFeatureTable(_ db: Database) throws {
        try db.create(table: "feature") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("issue_id", .text).notNull().unique()
            table.column("issue_id_for_display", .text)
            // The Feature issue's Linear `identifier` and board `url`, recorded by the Delta Read so the
            // Pulse can open it (issue #230). Nullable: none until the Delta Read next sees the issue.
            table.column("issue_key", .text)
            table.column("issue_url", .text)
            table.column("selected_night_id", .integer).references("night", column: "id")
            table.column("state", .text).notNull()
            table.column("reselection_count", .integer).notNull().defaults(to: 0)
            table.column("created_at", .text).notNull()
            // The Worktree name Yellowhammer requests (`yh-<project>-<feature>`), nullable: it is recorded
            // by the author Act, so a Feature has none until it is next authored. The Feature Branch
            // itself is per repository, on `feature_repository.branch`.
            table.column("worktree_name", .text)
            // When the predecessor gate released the Feature (roadmap P9.9).
            table.column("released_at", .text)
            // Which route closed a Feature (roadmap P10.7; spec: verification/archive-the-cycle-on-a-
            // verified-feature): `verification` when every Definition of Done clause was met, `merge`
            // when the Operator merged a Partial Landing (P10.8). Nullable — unset until a Feature closes.
            table.column("closed_by", .text)
                .check(sql: "closed_by IN ('verification','merge')")
        }
    }

    static func createCycleTable(_ db: Database) throws {
        try db.create(table: "cycle") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("feature_id", .integer).notNull().unique()
                .references("feature", column: "id", onDelete: .cascade)
            table.column("created_at", .text).notNull()
            table.column("archived_at", .text)
            // Nil until the land Act lands the Cycle once (roadmap P10.1; risks OQ8, once per Cycle).
            // Set by ``JournalStore/markCycleLanded(cycleID:runID:now:)``.
            table.column("landed_at", .text)
        }
    }

    static func createCardTable(_ db: Database) throws {
        try db.create(table: "card") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("cycle_id", .integer).notNull()
                .references("cycle", column: "id", onDelete: .cascade)
            table.column("issue_id", .text).notNull().unique()
            table.column("issue_id_for_display", .text)
            // The Card issue's Linear `identifier` and board `url`, recorded by the Delta Read so the
            // Pulse can open it (issue #230). Nullable: none until the Delta Read next sees the issue.
            table.column("issue_key", .text)
            table.column("issue_url", .text)
            table.column("repository", .text).notNull()
            table.column("kind", .text).notNull()
            table.column("authored_order", .integer).notNull()
            table.column("state", .text).notNull()
            table.column("waiting_reason", .text)
                .check(sql: "waiting_reason IN ('question','divergence')")
            table.column("block_reason", .text)
            table.column("budget_epoch", .integer).notNull().defaults(to: 0)
            table.column("consecutive_divergences", .integer).notNull().defaults(to: 0)
            table.column("failed_adoptions", .integer).notNull().defaults(to: 0)
            table.column("unanswered_nights", .integer).notNull().defaults(to: 0)
            table.column("created_at", .text).notNull()
            // What state a Card held before being marked Cancelled.
            table.column("cancelled_from_state", .text)
            // Card-side state versioning for board projection (roadmap P5.8): `state_version` is bumped
            // by every Journal-side Card state transition, and `board_state_version` records the version
            // last confirmed applied on the board — nil until the first confirmed write. Together they
            // are what ``JournalStore/cardsWithUnpostedState()`` reads to find every Card the board has
            // not caught up with, so a crashed run's board projection is reposted from the Journal
            // rather than replayed from the Outbox alone.
            table.column("state_version", .integer).notNull().defaults(to: 0)
            table.column("board_state_version", .integer)
            // The Card side of the unanswered-Nights clock (roadmap P11.4; spec:
            // bounds/bound-unanswered-nights): `unanswered_nights` is joined by the Night it was last
            // counted for, mirroring `refusal.last_counted_night_id` — nullable, because the Night a Card
            // enters Waiting on You never counts, and a Card that has never been in Waiting on You has
            // counted none.
            table.column("unanswered_last_counted_night_id", .integer)
                .references("night", column: "id")
            // The Divergence promotion Bound's marker (roadmap P11.6): the Night a Card's
            // `failed_adoptions` first exceeds `failed_adoptions_max`. Visibility only — neither a
            // state, a counter nor a budget. Cleared wherever the count resets.
            table.column("divergence_standing_night_id", .integer)
                .references("night", column: "id")
            // A Card's board title, so the Roll-up and the partial-landing PR body can name a Card that
            // did not complete by title instead of by issue id (issue #161; spec:
            // landing/announce-a-partial-landing). Nullable: a Card has no recorded title until the
            // Delta Read next reconciles it against the board.
            table.column("title", .text)
            table.uniqueKey(["cycle_id", "repository", "authored_order"])
        }
        try db.create(index: "idx_card_cycle_id", on: "card", columns: ["cycle_id"])
    }

    static func createAttemptTable(_ db: Database) throws {
        try db.create(table: "attempt") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("card_id", .integer).notNull()
                .references("card", column: "id", onDelete: .cascade)
            table.column("budget_epoch", .integer).notNull()
            table.column("route_cli", .text).notNull()
            table.column("route_model", .text).notNull()
            table.column("route_effort", .text).notNull()
            table.column("classification", .text)
            table.column("result", .text)
            table.column("consumed_how", .text)
            table.column("check_declared_none", .integer).notNull().defaults(to: 0)
            table.column("started_at", .text).notNull()
            table.column("ended_at", .text)
            // Attempt-side route provenance for route exclusion on retry
            // (routing/exclude-tried-routes-on-retry, P7.7), both nullable:
            // - `route_source` — how the Attempt's Route was selected: `entry` (the Routing Entry's
            //   primary route), `fallback:<n>` (the entry's nth fallback, 1-based), or `override` (the
            //   Operator's pin).
            // - `override_pin` — the Override pinned in triage at the moment this Attempt was recorded,
            //   rendered as its `description` (`cli/model/effort`, `-` for an absent axis), or nil.
            table.column("route_source", .text)
            table.column("override_pin", .text)
            // Preserved-work provenance (Attempt, Block and Reset Ruling 2026-09-19, OQ60): when a new
            // Attempt or a Block resets the Worktree to the last known-good commit, the prior Attempt's
            // own commits plus any WIP commit are preserved under a git ref before the reset, recorded
            // here against that Attempt — both nullable:
            // - `preserved_ref` — `refs/yellowhammer/attempts/<Feature Branch name>/<attempt id>`.
            // - `preserved_commit` — the Feature Branch tip the ref points at, just before the reset.
            table.column("preserved_ref", .text)
            table.column("preserved_commit", .text)
        }
        try db.create(index: "idx_attempt_card_id", on: "attempt", columns: ["card_id"])
    }

    static func createRoundTable(_ db: Database) throws {
        try db.create(table: "round") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("attempt_id", .integer).notNull()
                .references("attempt", column: "id", onDelete: .cascade)
            table.column("lens", .text).notNull()
                .check(sql: "lens IN ('review','check')")
            table.column("verdict", .text).notNull()
            table.column("requested_changes", .text)
            table.column("judged_commit", .text)
            table.column("created_at", .text).notNull()
        }
        try db.create(index: "idx_round_attempt_id", on: "round", columns: ["attempt_id"])
    }

    static func createRouteExclusionTable(_ db: Database) throws {
        try db.create(table: "route_exclusion") { table in
            table.column("card_id", .integer).notNull()
                .references("card", column: "id", onDelete: .cascade)
            table.column("budget_epoch", .integer).notNull()
            table.column("route_cli", .text).notNull()
            table.column("route_model", .text).notNull()
            table.column("route_effort", .text).notNull()
            table.column("reason", .text).notNull()
            table.column("excluded_at", .text).notNull()
            table.primaryKey(["card_id", "budget_epoch", "route_cli", "route_model", "route_effort"])
        }
    }
}
