import GRDB

/// The Journal's forward-only migrations (Decision Gates Ruling, G-4).
///
/// A migration, once shipped, is never edited or reordered: add a new one. The engine migrates on
/// open; the app never does, and refuses a store that knows a migration this build does not.
enum JournalMigrations {
    /// Every identifier this build knows, in registration order. Derived from the migrator so that
    /// the list and the registrations cannot drift apart.
    static var migrationIdentifiers: [String] {
        migrator.migrations
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-initial-schema") { db in
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
        }
        migrator.registerMigration("v2-act-lease") { db in
            try createActLeaseTable(db)
        }
        migrator.registerMigration("v3-night-close-reason") { db in
            try addNightCloseReasonColumn(db)
        }
        migrator.registerMigration("v4-outbox-delivery") { db in
            try addOutboxDeliveryColumns(db)
        }
        migrator.registerMigration("v5-delta-read") { db in
            try addDeltaReadTracking(db)
        }
        migrator.registerMigration("v6-night-verdict") { db in
            try addNightVerdictColumn(db)
        }
        migrator.registerMigration("v7-card-state-version") { db in
            try addCardStateVersions(db)
        }
        migrator.registerMigration("v8-worktree-pushed-commit") { db in
            try addWorktreePushedCommit(db)
        }
        migrator.registerMigration("v9-worktree-reconciliation") { db in
            try addWorktreeReconciliationColumns(db)
        }
        migrator.registerMigration("v10-attempt-route-provenance") { db in
            try addAttemptRouteProvenance(db)
        }
        migrator.registerMigration("v11-feature-branch") { db in
            try addFeatureBranchColumn(db)
        }
        migrator.registerMigration("v12-readiness-check") { db in
            try addReadinessCheckTables(db)
        }
        migrator.registerMigration("v13-card-scope") { db in
            try addCardScopeTable(db)
        }
        return migrator
    }
}
