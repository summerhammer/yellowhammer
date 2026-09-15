import GRDB

// These functions belong to migration v1 and are frozen; a later migration must not call them with changes.
extension JournalMigrations {
    static func createNightTable(_ db: Database) throws {
        try db.create(table: "night") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("project_id", .text).notNull()
            table.column("night_start", .text).notNull()
            table.column("mode", .text).notNull()
                .check(sql: "mode IN ('real','rehearsal')")
            table.column("state", .text).notNull()
            table.column("night_card_issue_id", .text)
            table.column("opened_at", .text).notNull()
            table.column("completed_at", .text)
            table.uniqueKey(["project_id", "night_start"])
        }
    }

    static func createFeatureTable(_ db: Database) throws {
        try db.create(table: "feature") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("issue_id", .text).notNull().unique()
            table.column("selected_night_id", .integer).references("night", column: "id")
            table.column("state", .text).notNull()
            table.column("reselection_count", .integer).notNull().defaults(to: 0)
            table.column("created_at", .text).notNull()
        }
    }

    static func createCycleTable(_ db: Database) throws {
        try db.create(table: "cycle") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("feature_id", .integer).notNull().unique()
                .references("feature", column: "id", onDelete: .cascade)
            table.column("created_at", .text).notNull()
            table.column("archived_at", .text)
        }
    }

    static func createCardTable(_ db: Database) throws {
        try db.create(table: "card") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("cycle_id", .integer).notNull()
                .references("cycle", column: "id", onDelete: .cascade)
            table.column("issue_id", .text).notNull().unique()
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

    static func createLeaseTable(_ db: Database) throws {
        try db.create(table: "lease") { table in
            table.column("card_id", .integer).primaryKey()
                .references("card", column: "id", onDelete: .cascade)
            table.column("run_id", .text).notNull()
            table.column("claimed_at", .text).notNull()
            table.column("heartbeat_at", .text).notNull()
            table.column("expires_at", .text).notNull()
        }
    }

    static func createWorktreeTable(_ db: Database) throws {
        try db.create(table: "worktree") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("feature_id", .integer).notNull()
                .references("feature", column: "id", onDelete: .cascade)
            table.column("repository", .text).notNull()
            table.column("worktree_id", .text).notNull()
            table.column("path", .text).notNull()
            table.column("created_at", .text).notNull()
            table.column("released_at", .text)
            table.uniqueKey(["feature_id", "repository", "worktree_id"])
        }
        try db.create(index: "idx_worktree_feature_id", on: "worktree", columns: ["feature_id"])
    }

    static func createFailureCauseTable(_ db: Database) throws {
        try db.create(table: "failure_cause") { table in
            table.column("card_id", .integer).notNull()
                .references("card", column: "id", onDelete: .cascade)
            table.column("cause_hash", .text).notNull()
            table.column("recurrence_count", .integer).notNull().defaults(to: 1)
            table.column("first_night_id", .integer).notNull()
                .references("night", column: "id", onDelete: .cascade)
            table.column("last_night_id", .integer).notNull()
                .references("night", column: "id", onDelete: .cascade)
            table.primaryKey(["card_id", "cause_hash"])
        }
    }

    static func createManagedBlockTable(_ db: Database) throws {
        try db.create(table: "managed_block") { table in
            table.column("issue_id", .text).primaryKey()
            table.column("last_posted_hash", .text).notNull()
            table.column("posted_at", .text).notNull()
        }
    }

    static func createClauseTable(_ db: Database) throws {
        try db.create(table: "clause") { table in
            table.column("cid", .text).notNull()
            table.column("issue_id", .text).notNull()
            table.column("level", .text).notNull()
                .check(sql: "level IN ('card','feature')")
            table.column("text", .text).notNull()
            table.column("location_id", .text).notNull()
            table.column("provenance", .text).notNull()
                .check(sql: "provenance IN ('machine-found','Author-supplied')")
            table.column("citation_provenance", .text).notNull().defaults(to: "machine-found")
                .check(sql: "citation_provenance IN ('machine-found','Author-supplied')")
            table.column("invalidated", .integer).notNull().defaults(to: 0)
            table.column("invalidated_cause", .text)
                .check(sql: "invalidated_cause IN ('text_edited','citation_edited')")
            table.column("deleted", .integer).notNull().defaults(to: 0)
            table.column("created_at", .text).notNull()
            table.primaryKey(["issue_id", "cid"])
        }
        try db.create(index: "idx_clause_issue_id", on: "clause", columns: ["issue_id"])
    }

    static func createTranscriptionBlockTable(_ db: Database) throws {
        try db.create(table: "transcription_block") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("card_id", .integer).notNull()
                .references("card", column: "id", onDelete: .cascade)
            table.column("repository", .text).notNull()
            table.column("paths", .text).notNull()
            table.column("symbol", .text)
            table.column("mainline_commit", .text)
            table.column("content_hash", .text).notNull()
            table.column("author_supplied", .integer).notNull().defaults(to: 0)
            table.column("author_supplied_night_id", .integer)
                .references("night", column: "id", onDelete: .cascade)
        }
        try db.create(index: "idx_transcription_block_card_id", on: "transcription_block", columns: ["card_id"])
    }

    static func createOutboxTable(_ db: Database) throws {
        try db.create(table: "outbox") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("client_id", .text).notNull().unique()
            table.column("issue_id", .text)
            table.column("operation", .text).notNull()
            table.column("payload", .text).notNull()
            table.column("run_id", .text)
            table.column("created_at", .text).notNull()
            table.column("sent_at", .text)
            table.column("last_error", .text)
        }
    }

    static func createBankedReplyTable(_ db: Database) throws {
        try db.create(table: "banked_reply") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("card_id", .integer).notNull()
                .references("card", column: "id", onDelete: .cascade)
            table.column("night_id", .integer).notNull()
                .references("night", column: "id", onDelete: .cascade)
            table.column("comment_id", .text).notNull().unique()
            table.column("body", .text).notNull()
            table.column("banked_at", .text).notNull()
        }
        try db.create(index: "idx_banked_reply_card_id", on: "banked_reply", columns: ["card_id"])
        try db.create(index: "idx_banked_reply_night_id", on: "banked_reply", columns: ["night_id"])
    }

    static func createBankedReplyMainlineTable(_ db: Database) throws {
        try db.create(table: "banked_reply_mainline") { table in
            table.column("banked_reply_id", .integer).notNull()
                .references("banked_reply", column: "id", onDelete: .cascade)
            table.column("repository", .text).notNull()
            table.column("mainline_commit", .text).notNull()
            table.primaryKey(["banked_reply_id", "repository"])
        }
    }

    static func createProjectStateTable(_ db: Database) throws {
        try db.create(table: "project_state") { table in
            table.column("id", .integer).primaryKey()
                .check(sql: "id = 1")
            table.column("consecutive_refusals", .integer).notNull().defaults(to: 0)
        }
        // Insert the single row
        try db.execute(
            sql: "INSERT INTO project_state (id, consecutive_refusals) VALUES (1, 0)"
        )
    }

    static func createEventTable(_ db: Database) throws {
        try db.create(table: "event") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("night_id", .integer)
                .references("night", column: "id", onDelete: .cascade)
            table.column("act", .text)
            table.column("run_id", .text)
            table.column("type", .text).notNull()
            table.column("occurred_at", .text).notNull()
            table.column("payload", .text)
        }
        // Create indexes
        try db.create(index: "idx_event_night_id", on: "event", columns: ["night_id"])
        try db.create(index: "idx_event_type", on: "event", columns: ["type"])

        // Create triggers to enforce append-only
        try db.execute(
            sql: """
            CREATE TRIGGER event_no_update
            BEFORE UPDATE ON event
            BEGIN
                SELECT RAISE(ABORT, 'event is append-only');
            END
            """
        )
        try db.execute(
            sql: """
            CREATE TRIGGER event_no_delete
            BEFORE DELETE ON event
            BEGIN
                SELECT RAISE(ABORT, 'event is append-only');
            END
            """
        )
    }
}
