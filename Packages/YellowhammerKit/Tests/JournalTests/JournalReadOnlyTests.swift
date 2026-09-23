import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

struct JournalReadOnlyTests {
    // MARK: - Test Helpers

    func createTempHome() -> URL {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yellowhammer-tests-\(UUID().uuidString)")
        return tempDir
    }

    func cleanupTempHome(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Test: openReadOnly behavior

    @Test
    func openReadOnlyBehavior() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let projectID = try #require(ProjectID(rawValue: "readonly-test"))
        let fileURL = JournalStore.defaultFileURL(homeDirectory: home, id: projectID)

        // Open with write access
        _ = try JournalStore.open(at: fileURL, projectID: projectID)

        // Open with read-only access
        let readOnlyJournal = try JournalStore.openReadOnly(at: fileURL, projectID: projectID)

        // Verify read succeeds
        let tables = try readOnlyJournal.tableNames()
        #expect(tables.count == 30)

        // Verify write fails
        var writeFailed = false
        do {
            try readOnlyJournal.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO night (project_id, night_start, mode, state, opened_at)
                    VALUES ('p1', '2026-01-01', 'real', 'active', '2026-01-01T00:00:00Z')
                    """
                )
            }
        } catch {
            writeFailed = true
        }
        #expect(writeFailed)
    }

    // MARK: - Test: openReadOnly missing file

    @Test
    func openReadOnlyMissingFile() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let projectID = try #require(ProjectID(rawValue: "missing-test"))
        let fileURL = JournalStore.defaultFileURL(homeDirectory: home, id: projectID)

        var error: JournalError?
        do {
            _ = try JournalStore.openReadOnly(at: fileURL, projectID: projectID)
        } catch let journalError as JournalError {
            error = journalError
        }

        #expect(error != nil)
        guard case .missing = error else {
            Issue.record("Expected .missing error")
            return
        }
    }

    // MARK: - Test: openReadOnly schema newer than known

    @Test
    func openReadOnlySchemaNewer() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let projectID = try #require(ProjectID(rawValue: "newer-schema-test"))
        let fileURL = JournalStore.defaultFileURL(homeDirectory: home, id: projectID)

        // Open normally to create and migrate
        _ = try JournalStore.open(at: fileURL, projectID: projectID)

        // Inject unknown migration
        try JournalStore.open(at: fileURL, projectID: projectID).write { db in
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99-from-the-future')"
            )
        }

        // Try to open read-only
        var error: JournalError?
        do {
            _ = try JournalStore.openReadOnly(at: fileURL, projectID: projectID)
        } catch let journalError as JournalError {
            error = journalError
        }

        #expect(error != nil)
        guard case .schemaNewerThanKnown = error else {
            Issue.record("Expected .schemaNewerThanKnown error")
            return
        }
    }

    // MARK: - Test: openReadOnly on 0-byte file

    @Test
    func openReadOnlyZeroByteFile() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let projectID = try #require(ProjectID(rawValue: "zerobyte-test"))
        let fileURL = JournalStore.defaultFileURL(homeDirectory: home, id: projectID)

        // Create directory and empty 0-byte file
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)

        // Try to open read-only
        var error: JournalError?
        do {
            _ = try JournalStore.openReadOnly(at: fileURL, projectID: projectID)
        } catch let journalError as JournalError {
            error = journalError
        }

        #expect(error != nil)
        guard case .schemaBehind = error else {
            Issue.record("Expected .schemaBehind error for 0-byte file")
            return
        }
    }
}
