import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
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
