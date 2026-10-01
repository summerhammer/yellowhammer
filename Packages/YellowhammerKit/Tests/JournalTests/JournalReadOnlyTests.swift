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
        #expect(tables.count == 33)

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

    // MARK: - Test: unknown migrations are classified as older or newer

    /// An identifier one schema version above the current one, built from `JournalMigrations.schemaIdentifier`.
    func newerIdentifier() throws -> String {
        let prefix = "journal-schema-"
        let current = try #require(Int(JournalMigrations.schemaIdentifier.dropFirst(prefix.count)))
        return "\(prefix)\(current + 1)"
    }

    /// Creates a Journal, records the given identifiers through a raw connection, and returns its URL.
    func journal(named name: String, home: URL, injecting identifiers: [String]) throws -> (URL, ProjectID) {
        let projectID = try #require(ProjectID(rawValue: name))
        let fileURL = JournalStore.defaultFileURL(homeDirectory: home, id: projectID)
        _ = try JournalStore.open(at: fileURL, projectID: projectID)
        let raw = try DatabaseQueue(path: fileURL.path)
        try raw.write { db in
            for identifier in identifiers {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
            }
        }
        return (fileURL, projectID)
    }

    func readOnlyError(_ fileURL: URL, _ projectID: ProjectID) -> JournalError? {
        do {
            _ = try JournalStore.openReadOnly(at: fileURL, projectID: projectID)
        } catch let journalError as JournalError {
            return journalError
        } catch {
            return nil
        }
        return nil
    }

    @Test
    func openReadOnlySchemaNewer() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let (fileURL, projectID) = try journal(
            named: "newer-schema-test", home: home, injecting: [try newerIdentifier()]
        )

        guard case .schemaNewerThanKnown = readOnlyError(fileURL, projectID) else {
            Issue.record("Expected .schemaNewerThanKnown error")
            return
        }
    }

    @Test
    func openReadOnlyRetiredChainIsOlder() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let (fileURL, projectID) = try journal(
            named: "older-chain-test", home: home, injecting: ["v30-card-title"]
        )

        guard case .schemaOlderThanKnown(_, let unknown) = readOnlyError(fileURL, projectID) else {
            Issue.record("Expected .schemaOlderThanKnown error")
            return
        }
        #expect(unknown == ["v30-card-title"])
    }

    @Test
    func openReadOnlyLowerSchemaNumberIsOlder() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let (fileURL, projectID) = try journal(
            named: "older-number-test", home: home, injecting: ["journal-schema-0"]
        )

        guard case .schemaOlderThanKnown = readOnlyError(fileURL, projectID) else {
            Issue.record("Expected .schemaOlderThanKnown error")
            return
        }
    }

    @Test
    func openReadOnlyMixOfOlderAndNewerIsNewer() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let (fileURL, projectID) = try journal(
            named: "mixed-test", home: home, injecting: ["v1-initial-schema", try newerIdentifier()]
        )

        guard case .schemaNewerThanKnown = readOnlyError(fileURL, projectID) else {
            Issue.record("Expected .schemaNewerThanKnown error")
            return
        }
    }

    @Test
    func openReadOnlyUnparseableIdentifierIsNewer() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        let (fileURL, projectID) = try journal(
            named: "unparseable-test", home: home, injecting: ["something-else"]
        )

        guard case .schemaNewerThanKnown = readOnlyError(fileURL, projectID) else {
            Issue.record("Expected .schemaNewerThanKnown error")
            return
        }
    }

    @Test
    func olderBuildDescriptionTellsTheOperatorToDelete() {
        let text = JournalError.schemaOlderThanKnown(path: "/tmp/p.db", unknown: ["v1-initial-schema"]).description
        #expect(text.contains("earlier build"))
        #expect(text.contains("Delete it"))
    }

    // MARK: - Test: engine open refuses a Journal with unknown migrations

    @Test
    func engineOpenRefusesUnknownMigrations() throws {
        let home = createTempHome()
        defer { try? cleanupTempHome(home) }

        // A pre-squash Journal carries identifiers this build does not know.
        let (fileURL, projectID) = try journal(
            named: "engine-older-schema-test", home: home, injecting: ["v1-initial-schema"]
        )

        var error: JournalError?
        do {
            _ = try JournalStore.open(at: fileURL, projectID: projectID)
        } catch let journalError as JournalError {
            error = journalError
        }

        guard case .schemaOlderThanKnown(_, let unknown) = error else {
            Issue.record("Expected .schemaOlderThanKnown error, got \(String(describing: error))")
            return
        }
        #expect(unknown == ["v1-initial-schema"])
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
