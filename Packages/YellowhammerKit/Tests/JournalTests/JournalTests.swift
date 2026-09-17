import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

struct JournalTests {
    // MARK: - Test Helpers

    func createTempHome() -> URL {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yellowhammer-tests-\(UUID().uuidString)")
        return tempDir
    }

    func cleanupTempHome(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Test: defaultFileURL format

    @Test
    func defaultFileURLFormat() throws {
        let home = URL(fileURLWithPath: "/home/user")
        let projectID = try #require(ProjectID(rawValue: "my-project"))
        let url = JournalStore.defaultFileURL(homeDirectory: home, id: projectID)

        #expect(url.path == "/home/user/.config/yellowhammer/journals/my-project.db")
    }

    // MARK: - Test: open creates file and directory, applies migrations

    @Test
    func openCreatesFileAndDirectory() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let projectID = try #require(ProjectID(rawValue: "test-project"))
        let journal = try JournalStore.open(homeDirectory: home, projectID: projectID)

        let fileURL = JournalStore.defaultFileURL(homeDirectory: home, id: projectID)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(journal.fileURL == fileURL)
        #expect(journal.projectID == projectID)

        let applied = try journal.appliedMigrations()
        #expect(applied == JournalStore.migrationIdentifiers)
    }

    // MARK: - Test: Two projects get separate files

    @Test
    func separateProjectsSeparateFiles() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let project1 = try #require(ProjectID(rawValue: "project-1"))
let project2 = try #require(ProjectID(rawValue: "project-2"))

        let journal1 = try JournalStore.open(homeDirectory: home, projectID: project1)
        let journal2 = try JournalStore.open(homeDirectory: home, projectID: project2)

        #expect(journal1.fileURL != journal2.fileURL)

        let applied1 = try journal1.appliedMigrations()
        let applied2 = try journal2.appliedMigrations()
        #expect(applied1 == JournalStore.migrationIdentifiers)
        #expect(applied2 == JournalStore.migrationIdentifiers)

        // Write to journal1 and verify isolation
        try journal1.write { db in
            try db.execute(
                sql: """
                INSERT INTO night (project_id, night_start, mode, state, opened_at)
                VALUES ('p1', '2026-01-01', 'real', 'active', '2026-01-01T00:00:00Z')
                """
            )
        }

        // Verify journal2 doesn't see the row
        let count1 = try journal1.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM night") ?? 0
        }
        let count2 = try journal2.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM night") ?? 0
        }

        #expect(count1 == 1)
        #expect(count2 == 0)
    }

    // MARK: - Test: Empty file opens and migrates

    @Test
    func emptyFileOpensAndMigrates() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let projectID = try #require(ProjectID(rawValue: "empty-test"))
        let fileURL = JournalStore.defaultFileURL(homeDirectory: home, id: projectID)

        // Create directory and empty file
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)

        // Open the empty file
        let journal = try JournalStore.open(at: fileURL, projectID: projectID)
        let applied = try journal.appliedMigrations()

        #expect(applied == JournalStore.migrationIdentifiers)
    }

    // MARK: - Test: Re-opening is idempotent

    @Test
    func reopeningIsIdempotent() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let projectID = try #require(ProjectID(rawValue: "idempotent-test"))

        let journal1 = try JournalStore.open(homeDirectory: home, projectID: projectID)
        let applied1 = try journal1.appliedMigrations()

        let journal2 = try JournalStore.open(homeDirectory: home, projectID: projectID)
        let applied2 = try journal2.appliedMigrations()

        #expect(applied1 == applied2)
        #expect(applied1 == JournalStore.migrationIdentifiers)
    }

    // MARK: - Test: tableNames contains all tables

    @Test
    func tableNamesContainsAllTables() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let projectID = try #require(ProjectID(rawValue: "tables-test"))
        let journal = try JournalStore.open(homeDirectory: home, projectID: projectID)

        let tables = try journal.tableNames()
        let expected = [
            "act_lease",
            "architectural_brief",
            "attempt",
            "banked_reply",
            "banked_reply_mainline",
            "board_sync",
            "card",
            "clause",
            "cycle",
            "event",
            "failure_cause",
            "feature",
            "lease",
            "managed_block",
            "night",
            "outbox",
            "project_state",
            "round",
            "route_exclusion",
            "transcription_block",
            "worktree"
        ]

        #expect(tables == expected)
    }

    // MARK: - Test: event append-only enforcement

    @Test
    func eventAppendOnlyEnforcement() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let projectID = try #require(ProjectID(rawValue: "event-test"))
        let journal = try JournalStore.open(homeDirectory: home, projectID: projectID)

        let eventID = try journal.write { db -> Int in
            try db.execute(
                sql: """
                INSERT INTO event (type, occurred_at)
                VALUES ('test_event', '2026-01-01T00:00:00Z')
                """
            )
            return try Int.fetchOne(db, sql: "SELECT last_insert_rowid()") ?? 0
        }

        // Verify update fails
        var updateFailed = false
        try journal.write { db in
            do {
                try db.execute(
                    sql: "UPDATE event SET type = 'modified' WHERE id = ?",
                    arguments: [eventID]
                )
            } catch {
                updateFailed = true
            }
        }
        #expect(updateFailed)

        // Verify delete fails
        var deleteFailed = false
        try journal.write { db in
            do {
                try db.execute(
                    sql: "DELETE FROM event WHERE id = ?",
                    arguments: [eventID]
                )
            } catch {
                deleteFailed = true
            }
        }
        #expect(deleteFailed)

        // Verify row still exists
        let count = try journal.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event WHERE id = ?", arguments: [eventID]) ?? 0
        }
        #expect(count == 1)
    }

    // MARK: - Test: project_state has exactly one row

    @Test
    func projectStateRow() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let projectID = try #require(ProjectID(rawValue: "state-test"))
        let journal = try JournalStore.open(homeDirectory: home, projectID: projectID)

        let (id, refusals) = try journal.read { db -> (Int, Int) in
            let id = try Int.fetchOne(db, sql: "SELECT id FROM project_state WHERE id = 1") ?? 0
            let refusals = try Int.fetchOne(db, sql: "SELECT consecutive_refusals FROM project_state WHERE id = 1") ?? 0
            return (id, refusals)
        }

        #expect(id == 1)
        #expect(refusals == 0)
    }

    // MARK: - Test: FK enforcement

    @Test
    func foreignKeyEnforcement() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let projectID = try #require(ProjectID(rawValue: "fk-test"))
        let journal = try JournalStore.open(homeDirectory: home, projectID: projectID)

        var fkFailed = false
        do {
            try journal.write { db in
                // Try to insert a card with nonexistent cycle_id
                try db.execute(
                    sql: """
                    INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, created_at)
                    VALUES (99999, 'issue-1', 'repo', 'test', 1, 'active', '2026-01-01T00:00:00Z')
                    """
                )
            }
        } catch {
            fkFailed = true
        }

        #expect(fkFailed)
    }
}
