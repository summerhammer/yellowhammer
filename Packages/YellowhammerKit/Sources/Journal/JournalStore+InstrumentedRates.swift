import GRDB

extension JournalStore {
    /// Current count of surviving clauses whose citation was supplied or edited by the Author.
    /// Read at Night close; the rendered Night Card preserves that Night's snapshot.
    public func authorSuppliedCitationCount() throws -> Int {
        try read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clause WHERE deleted = 0 AND citation_provenance = 'Author-supplied'"
            ) ?? 0
        }
    }

    public func closingAuthorSuppliedCitationCount(nightID: Int64) throws -> Int? {
        try read { db in
            try Int.fetchOne(
                db, sql: "SELECT closing_author_supplied_citation_count FROM night WHERE id = ?",
                arguments: [nightID]
            )
        }
    }
}
