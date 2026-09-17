import GRDB

/// The Ledger's forward-only migrations (Decision Gates Ruling, G-4).
///
/// A migration, once shipped, is never edited or reordered: add a new one. The engine migrates on
/// open; the app never does, and refuses a store that knows a migration this build does not.
enum LedgerMigrations {
    /// Every identifier this build knows, in registration order. Derived from the migrator so that
    /// the list and the registrations cannot drift apart.
    static var migrationIdentifiers: [String] {
        migrator.migrations
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-probe-result-history") { db in
            try createProbeResultTable(db)
        }
        migrator.registerMigration("v2-probe-session-resumption") { db in
            try addSessionResumptionColumn(db)
        }
        return migrator
    }
}
