import GRDB

extension JournalMigrations {
    /// The Act-scoped lease: at most one Act of this Project runs at a time, one level above the
    /// per-Card `lease`. A single row, so the schema itself refuses two holders. It carries `mode`
    /// so that rehearsal alongside real can be decided on its own later.
    static func createActLeaseTable(_ db: Database) throws {
        try db.create(table: "act_lease") { table in
            table.column("id", .integer).primaryKey().check(sql: "id = 1")
            table.column("act", .text).notNull()
                .check(sql: "act IN ('author','build','land')")
            table.column("run_id", .text).notNull()
            table.column("mode", .text).notNull()
                .check(sql: "mode IN ('real','rehearsal')")
            table.column("claimed_at", .text).notNull()
            table.column("heartbeat_at", .text).notNull()
            table.column("expires_at", .text).notNull()
        }
    }

    /// The `board_sync` table tracks the last Delta Read sync point.
    static func createBoardSyncTable(_ db: Database) throws {
        try db.create(table: "board_sync") { table in
            table.column("id", .integer).primaryKey()
                .check(sql: "id = 1")
            table.column("last_sync", .text).notNull()
            table.column("read_at", .text).notNull()
            table.column("run_id", .text)
        }
    }

    /// The Journal-side storage the Readiness Check needs (P8.2): the Architectural Brief's prose,
    /// one row per Card.
    static func createArchitecturalBriefTable(_ db: Database) throws {
        try db.create(table: "architectural_brief") { table in
            table.column("card_id", .integer).primaryKey()
                .references("card", column: "id", onDelete: .cascade)
            table.column("prose", .text).notNull()
            table.column("recorded_at", .text).notNull()
        }
    }

    /// The Journal's storage for a Card's declared scope (bounds/refuse-protected-paths-before-dispatch,
    /// roadmap P8.3): the paths the Card is authored to touch, in authored order, one row per path.
    static func createCardScopeTable(_ db: Database) throws {
        try db.create(table: "card_scope") { table in
            table.column("card_id", .integer).notNull()
                .references("card", column: "id", onDelete: .cascade)
            table.column("position", .integer).notNull()
            table.column("path", .text).notNull()
            table.primaryKey(["card_id", "position"])
        }
    }

    /// The Refusal table (roadmap P9.7; glossary: Refusal): a Feature's uncitable-Definition-of-Done
    /// halt (``AuthoringHaltReason/uncitableDefinitionOfDone``), tracked per Feature name because a
    /// Refusal can exist before the Journal has a `feature` row for it — the Feature Issue is created
    /// in Waiting on You before authoring is ever accepted into the Outbox.
    ///
    /// `content` keeps the halt reason's detail so it survives expiry, when the halt itself is no
    /// longer the newest thing recorded against the Feature. `unanswered_nights` and
    /// `last_counted_night_id` are the Night-driven clock (bounds/bound-unanswered-nights): a Night
    /// counts toward it only once, and only when it is not the Night the Refusal opened on. At most one
    /// open row exists per Feature name — enforced by a partial unique index, not a table constraint,
    /// because `answered`/`expired`/`standing_item` rows for the same Feature name are expected to pile
    /// up across its lifetime.
    ///
    /// The state CHECK has no `closed` value, so a Refusal a clean authoring run has closed is marked
    /// by `closed_night_id` being non-null, and the one-open-row index ignores closed rows (a closed
    /// `open` row must not block a fresh one).
    ///
    /// `standing_item_night_id` is the refusal-drift Bound's marker (roadmap P11.6): set once, the Night
    /// a Refusal's consecutive count first exceeds `consecutive_refusals_max`. Visibility only — it never
    /// moves `state`, which the Unanswered Position Clock and the answer path still select on. Cleared
    /// wherever the count resets.
    static func createRefusalTable(_ db: Database) throws {
        try db.create(table: "refusal") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("feature_name", .text).notNull()
            table.column("issue_id", .text)
            table.column("state", .text).notNull()
                .check(sql: "state IN ('open','answered','expired','standing_item')")
            table.column("content", .text).notNull()
            table.column("opened_night_id", .integer).notNull()
                .references("night", column: "id")
            table.column("unanswered_nights", .integer).notNull().defaults(to: 0)
            table.column("last_counted_night_id", .integer)
                .references("night", column: "id")
            table.column("consecutive_refusals", .integer).notNull()
            table.column("expired_night_id", .integer)
                .references("night", column: "id")
            table.column("created_at", .text).notNull()
            table.column("closed_night_id", .integer)
                .references("night", column: "id")
            table.column("standing_item_night_id", .integer)
                .references("night", column: "id")
        }
        try db.create(index: "idx_refusal_feature_name", on: "refusal", columns: ["feature_name"])
        // A partial index: GRDB's table-builder DSL has no `WHERE` clause for a unique constraint, so
        // this one is raw SQL, same as the event table's append-only triggers.
        try db.execute(
            sql: """
            CREATE UNIQUE INDEX idx_refusal_open_per_feature ON refusal(feature_name)
            WHERE state = 'open' AND closed_night_id IS NULL
            """
        )
    }

    /// The Authoring Halt as its own object (roadmap P9.8; glossary: Authoring Halt, Refusal): a Feature
    /// whose authoring stopped for a reason that is not a thin specification — no backward-compatible
    /// seam, undeterminable repositories, a repository outside the Project, an unreadable contract.
    /// Tracked per Feature name for the same reason the Refusal is: the Feature Issue exists before any
    /// `feature` row does.
    ///
    /// The clock columns are the Refusal's (bounds/bound-unanswered-nights), and a halt has NO consecutive
    /// count of any kind — only a Refusal counts. At most one `open` row per Feature name, by partial
    /// unique index. A halt has no `answered` state: it clears when that Feature next authors cleanly.
    static func createAuthoringHaltTable(_ db: Database) throws {
        try db.create(table: "authoring_halt") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("feature_name", .text).notNull()
            table.column("issue_id", .text)
            table.column("state", .text).notNull()
                .check(sql: "state IN ('open','expired','cleared')")
            table.column("cause_kind", .text).notNull()
            table.column("content", .text).notNull()
            table.column("opened_night_id", .integer).notNull()
                .references("night", column: "id")
            table.column("unanswered_nights", .integer).notNull().defaults(to: 0)
            table.column("last_counted_night_id", .integer)
                .references("night", column: "id")
            table.column("expired_night_id", .integer)
                .references("night", column: "id")
            table.column("created_at", .text).notNull()
        }
        try db.create(index: "idx_authoring_halt_feature_name", on: "authoring_halt", columns: ["feature_name"])
        try db.execute(
            sql: """
            CREATE UNIQUE INDEX idx_authoring_halt_open_per_feature ON authoring_halt(feature_name)
            WHERE state = 'open'
            """
        )
    }

    /// The predecessor gate's own durable state (roadmap P9.9; spec: feature-authoring/
    /// select-the-next-feature, third story): the repositories a Feature touches, recorded at
    /// selection time rather than derived from its Cards (a Card's repository row can disappear —
    /// cancelled, adopted elsewhere — long after the Feature that touched it is a predecessor), the
    /// landings the gate has observed for it, and (on `feature.abandoned_at`) whether it has been abandoned.
    static func createFeatureLandingTables(_ db: Database) throws {
        try db.create(table: "feature_repository") { table in
            table.column("feature_id", .integer).notNull()
                .references("feature", column: "id", onDelete: .cascade)
            table.column("repository", .text).notNull()
            // The Feature Branch Orca ADE reported at this repository's first allocation. NULL until
            // then; never changed once set.
            table.column("branch", .text)
            // The Feature Branch tip a ghost-Worktree purge pinned at
            // `refs/yellowhammer/recovery/<branch>`. NULL except between that purge and the
            // re-allocation that verifies the re-created branch (OQ123).
            table.column("recovery_commit", .text)
            table.primaryKey(["feature_id", "repository"])
        }

        try db.create(table: "feature_landing") { table in
            table.column("feature_id", .integer).notNull()
                .references("feature", column: "id", onDelete: .cascade)
            table.column("repository", .text).notNull()
            table.column("mainline_commit", .text).notNull()
            table.column("observed_at", .text).notNull()
            table.primaryKey(["feature_id", "repository"])
        }
    }

    /// Records a Repo Lane's opened pull request, once (roadmap P10.4): `url` is nullable because
    /// GitHub reporting `.alreadyOpen` carries no URL — this Port never reads pull request state.
    /// Unique on `(feature_id, repository)` so a first write wins and a pull request is never
    /// duplicated for the same Feature's repository.
    static func createPullRequestTable(_ db: Database) throws {
        try db.create(table: "pull_request") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("feature_id", .integer).notNull()
                .references("feature", column: "id", onDelete: .cascade)
            table.column("repository", .text).notNull()
            table.column("url", .text)
            table.column("night_id", .integer).notNull()
                .references("night", column: "id")
            table.column("run_id", .text).notNull()
            table.column("opened_at", .text).notNull()
            table.uniqueKey(["feature_id", "repository"])
        }
    }

    /// Records a Cycle's Verification once (roadmap P10.5; spec: verification/verify-a-feature-clause-by-clause).
    /// `feature_verification` is unique on `cycle_id`: a Cycle is judged once, so a retried land Act
    /// reuses the record. `route` is nil when no verifier dispatch was needed. `clause_verification`
    /// snapshots each clause's text, citation and citation provenance as judged, so the report stays as
    /// the verifier saw it however the board's clause is edited later. `judged_by` says whether the
    /// verdict is the verifier's or one the engine decided itself.
    static func createFeatureVerificationTables(_ db: Database) throws {
        try db.create(table: "feature_verification") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("feature_id", .integer).notNull()
                .references("feature", column: "id", onDelete: .cascade)
            table.column("cycle_id", .integer).notNull().unique()
                .references("cycle", column: "id", onDelete: .cascade)
            table.column("route", .text)
            table.column("night_id", .integer).notNull()
                .references("night", column: "id")
            table.column("run_id", .text).notNull()
            table.column("verified_at", .text).notNull()
        }
        try db.create(table: "clause_verification") { table in
            table.column("verification_id", .integer).notNull()
                .references("feature_verification", column: "id", onDelete: .cascade)
            table.column("issue_id", .text).notNull()
            table.column("cid", .text).notNull()
            table.column("level", .text).notNull()
                .check(sql: "level IN ('card','feature')")
            table.column("text", .text).notNull()
            table.column("location_id", .text).notNull()
            table.column("citation_provenance", .text).notNull()
                .check(sql: "citation_provenance IN ('machine-found','Author-supplied')")
            table.column("verdict", .text).notNull()
                .check(sql: "verdict IN ('met','unmet','unresolved')")
            table.column("what_was_checked", .text).notNull()
            table.column("interpretation", .text).notNull()
            table.column("invalidated_cause", .text)
                .check(sql: "invalidated_cause IN ('text_edited','citation_edited')")
            table.column("judged_by", .text).notNull()
                .check(sql: "judged_by IN ('agent','engine')")
            table.column("position", .integer).notNull()
            table.primaryKey(["verification_id", "issue_id", "cid"])
        }
    }

    /// The Card Question table (roadmap P11.1; spec: bounds/escalate-a-question-to-the-operator): a
    /// worker pass's question, recorded before the Card moves to Waiting on You. `comment_client_id` is
    /// the Outbox client id the question comment is posted under, nullable when there was no Outbox to
    /// post through, so a later Night (P11.2) can recognise a threaded reply to it.
    static func createCardQuestionTable(_ db: Database) throws {
        try db.create(table: "card_question") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("card_id", .integer).notNull()
                .references("card", column: "id", onDelete: .cascade)
            table.column("attempt_id", .integer).notNull()
                .references("attempt", column: "id", onDelete: .cascade)
            table.column("night_id", .integer).notNull()
                .references("night", column: "id")
            table.column("question", .text).notNull()
            table.column("comment_client_id", .text)
            table.column("asked_at", .text).notNull()
        }
        try db.create(index: "idx_card_question_card_id", on: "card_question", columns: ["card_id"])
    }

    /// The Card Reply table (roadmap P11.2; spec: bounds/escalate-a-question-to-the-operator,
    /// board-projection/read-board-changes-by-delta): one human comment the Delta Read classified
    /// against a Card in Waiting on You — an answer to the latest recorded question, a remark, or a
    /// reply to a Divergence notice. Recorded inside the Delta Read's reconciliation, idempotent on
    /// `comment_id`, before the sync point moves. `question_id` is nullable: a Divergence reply, or a
    /// remark recorded against a Card whose latest question row could not be found, carries none.
    /// `applied_at` is set only once the board-side transition and acknowledgement (a separate, later
    /// step) both returned without throwing, so a killed run between recording and applying loses
    /// nothing and a resumed run posts no duplicate acknowledgement.
    static func createCardReplyTable(_ db: Database) throws {
        try db.create(table: "card_reply") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("card_id", .integer).notNull()
                .references("card", column: "id", onDelete: .cascade)
            table.column("question_id", .integer)
                .references("card_question", column: "id")
            table.column("comment_id", .text).notNull().unique()
            table.column("body", .text).notNull()
            table.column("author_name", .text)
            table.column("disposition", .text).notNull()
            table.column("commented_at", .text).notNull()
            table.column("night_id", .integer).notNull()
                .references("night", column: "id")
            table.column("applied_at", .text)
        }
        try db.create(index: "idx_card_reply_card_id", on: "card_reply", columns: ["card_id"])
    }

    /// A failed Adoption's durable Divergence record (roadmap P11.5; spec: feature-authoring/
    /// author-the-cycle-and-card-dag, second story): one row per refusal, so they accumulate rather than
    /// overwrite — a sibling of `refusal`, never reused. `stale_blocks` is JSON-encoded, one entry per
    /// repository whose Transcription Block tested stale, so a single refusal can name more than one.
    static func createAdoptionRefusalTable(_ db: Database) throws {
        try db.create(table: "adoption_refusal") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("card_id", .integer).notNull()
                .references("card", column: "id", onDelete: .cascade)
            table.column("night_id", .integer).notNull()
                .references("night", column: "id")
            table.column("feature_name", .text).notNull()
            table.column("stale_blocks", .text).notNull()
            table.column("created_at", .text).notNull()
        }
        try db.create(index: "idx_adoption_refusal_card_id", on: "adoption_refusal", columns: ["card_id"])
    }

    /// The Operator's request to abort one open Attempt, written by `yh stop` from outside the Act that
    /// holds the Act Lease. The run that holds the Card Lease polls it and ends the Attempt `aborted`.
    /// The row is deleted with its Attempt.
    static func createOperatorAbortRequestTable(_ db: Database) throws {
        try db.create(table: "operator_abort_request") { table in
            table.column("attempt_id", .integer).primaryKey().references("attempt", onDelete: .cascade)
            table.column("requested_at", .text).notNull()
        }
    }
}
