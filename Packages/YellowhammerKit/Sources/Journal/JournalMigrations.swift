import GRDB

/// The Journal's schema migration (Decision Gates Ruling, G-4).
///
/// Pre-1.0 the Journal has a single migration that creates the whole current schema. Any schema
/// change edits it in place AND bumps its identifier (`journal-schema-1` becomes `journal-schema-2`),
/// so a Journal created by an older build is refused rather than silently kept on a stale schema;
/// existing development Journals are deleted and recreated. The migration stays forward-only and
/// engine-owned: the engine migrates on open; the app never does, and refuses a store that knows a
/// migration this build does not.
enum JournalMigrations {
    /// The identifier of the single schema migration. Bump it whenever the schema changes.
    static let schemaIdentifier = "journal-schema-1"

    /// Every identifier this build knows, in registration order. Derived from the migrator so that
    /// the list and the registrations cannot drift apart.
    static var migrationIdentifiers: [String] {
        migrator.migrations
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(schemaIdentifier) { db in
            try createNightTable(db)
            try createFeatureTable(db)
            try createCycleTable(db)
            try createCardTable(db)
            try createAttemptTable(db)
            try createRoundTable(db)
            try createRouteExclusionTable(db)
            try createLeaseTable(db)
            try createWorktreeTable(db)
            try createFailureCauseTable(db)
            try createManagedBlockTable(db)
            try createClauseTable(db)
            try createTranscriptionBlockTable(db)
            try createOutboxTable(db)
            try createBankedReplyTable(db)
            try createBankedReplyMainlineTable(db)
            try createProjectStateTable(db)
            try createEventTable(db)
            try createActLeaseTable(db)
            try createBoardSyncTable(db)
            try createArchitecturalBriefTable(db)
            try createCardScopeTable(db)
            try createRefusalTable(db)
            try createAuthoringHaltTable(db)
            try createFeatureLandingTables(db)
            try createPullRequestTable(db)
            try createFeatureVerificationTables(db)
            try createCardQuestionTable(db)
            try createCardReplyTable(db)
            try createAdoptionRefusalTable(db)
            try createOperatorAbortRequestTable(db)
        }
        return migrator
    }
}
