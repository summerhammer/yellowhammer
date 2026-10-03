import Domain
import Foundation
import GRDB

extension JournalMigrations {
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
            // Nil until the Feature Branch has been pushed and that push recorded. This is the release
            // gate (graph-execution/allocate-a-worktree-per-graph-and-repo): Orca ADE is asked to
            // remove a Worktree only once this column is set.
            table.column("pushed_commit", .text)
            // The columns worktree reconciliation needs (loop-state/reconcile-worktrees-at-act-start),
            // all nullable:
            // - `last_known_good_commit` — what a reset returns to (object-guide:
            //   Worktree.last_known_good_commit), set at allocation and advanced later once a Card's
            //   work is judged good, so a reset never rewinds accepted work.
            // - `wip_commit` — the WIP commit reconciliation wrote, handed to the retry as context.
            // - `lost_at` — when reconciliation found the recorded path gone: a ghost Worktree.
            table.column("last_known_good_commit", .text)
            table.column("wip_commit", .text)
            table.column("lost_at", .text)
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
            // The Transcription Block's own content (the renderer's round-trip source), nullable
            // because a block has none until it is next parsed (Readiness Check, P8.2).
            table.column("content", .text)
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
            // State machine columns, Card lease tracking, and group delivery support for
            // all-or-nothing board write sets. The delivery state machine progresses pending →
            // applied, failed, or aborted, once per entry. Outbox entries persist delivery history
            // for replay after a crash.
            table.column("card_id", .integer)
                .references("card", column: "id", onDelete: .setNull)
            table.column("group_id", .text)
            table.column("state", .text).notNull().defaults(to: "pending")
                .check(sql: "state IN ('pending','applied','failed','aborted')")
            table.column("result", .text)
            table.column("attempt_count", .integer).notNull().defaults(to: 0)
        }
        try db.create(index: "idx_outbox_state", on: "outbox", columns: ["state"])
        try db.create(index: "idx_outbox_group_id", on: "outbox", columns: ["group_id"])
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

    /// The single Project-state row. `outbox_salt` salts every Outbox client id this Journal computes
    /// (`OutboxClientID.make`) so a Project reset — Journal deleted, its Linear issues archived —
    /// never re-addresses an archived issue on replay. The row is inserted with a fresh random salt;
    /// the column default stays empty. `linear_workspace` records the Linear workspace of the App
    /// Installation the Journal was built against, in the same insert, so it is never absent and has no
    /// placeholder: a creation with no workspace throws.
    static func createProjectStateTable(_ db: Database, linearWorkspace: BoardObjectID?) throws {
        guard let linearWorkspace else { throw JournalError.linearWorkspaceRequired }
        try db.create(table: "project_state") { table in
            table.column("id", .integer).primaryKey()
                .check(sql: "id = 1")
            table.column("consecutive_refusals", .integer).notNull().defaults(to: 0)
            table.column("outbox_salt", .text).notNull().defaults(to: "")
            table.column("linear_workspace", .text).notNull()
        }
        // Insert the single row
        try db.execute(
            sql: """
            INSERT INTO project_state (id, consecutive_refusals, outbox_salt, linear_workspace)
            VALUES (1, 0, ?, ?)
            """,
            arguments: [UUID().uuidString.lowercased(), linearWorkspace.rawValue]
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
