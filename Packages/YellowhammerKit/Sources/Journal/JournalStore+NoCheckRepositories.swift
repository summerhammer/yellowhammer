import GRDB

extension JournalStore {
    /// The repositories of a Cycle's Cards whose Attempts ran under a declared `check = none`, sorted. Read
    /// from the Attempts' own recorded flag, never from current configuration, so a later edit to the
    /// Project's configuration cannot rewrite why an earlier Verification had no Check to lean on.
    public func repositoriesDeclaringNoCheck(cycleID: Int64) throws -> [String] {
        try read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT card.repository FROM attempt
                JOIN card ON card.id = attempt.card_id
                WHERE card.cycle_id = ? AND attempt.check_declared_none = 1
                ORDER BY card.repository ASC
                """,
                arguments: [cycleID]
            )
        }
    }
}
