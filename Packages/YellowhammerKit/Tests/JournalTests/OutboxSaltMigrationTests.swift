import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// The rehearsal cleanup deletes a Project's Journal and archives its Linear issues; a re-run then
// computed the same deterministic Outbox client id, matched the archived issue, and wrote invisibly
// into it. v29-outbox-salt salts every id this Journal computes with a value fixed for its life, so a
// reset Project's fresh Journal never re-addresses an issue the previous Journal already created.

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-outbox-salt-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("Migration V29: the Outbox salt")
struct OutboxSaltMigrationTests {
    @Test("A freshly created Journal has a non-empty, UUID-parseable outbox_salt")
    func freshJournalHasParseableSalt() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()

        #expect(!journal.outboxSalt.isEmpty)
        #expect(UUID(uuidString: journal.outboxSalt) != nil)
    }

    @Test("Two fresh Journals get different salts")
    func twoFreshJournalsGetDifferentSalts() throws {
        let first = try JournalFixture(project: "alpha").open()
        let second = try JournalFixture(project: "beta").open()

        #expect(first.outboxSalt != second.outboxSalt)
    }

    @Test("The salt survives close and reopen")
    func saltSurvivesReopen() throws {
        let fixture = try JournalFixture()
        let opened = try fixture.open()
        let salt = opened.outboxSalt

        let reopened = try fixture.open()
        #expect(reopened.outboxSalt == salt)
    }

    @Test("A Journal migrated to v28 WITH an Outbox row keeps the empty legacy salt after v29 runs")
    func journalWithOutboxRowKeepsLegacySalt() throws {
        let fixture = try JournalFixture()
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: fixture.projectID)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let v28 = try DatabaseQueue(path: fileURL.path)
        try JournalMigrations.migrator.migrate(v28, upTo: "v28-night-opening-board-snapshot")
        try v28.writeWithoutTransaction { db in
            try db.execute(
                sql: """
                INSERT INTO outbox (client_id, operation, payload, created_at)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [UUID().uuidString, "issueCreate", "{}", JournalStore.timestamp(epoch)]
            )
        }
        let columnsBefore = try v28.read { try $0.columns(in: "project_state") }.map(\.name)
        #expect(!columnsBefore.contains("outbox_salt"))

        let journal = try fixture.open()

        #expect(try journal.appliedMigrations().last == "v29-outbox-salt")
        #expect(journal.outboxSalt.isEmpty)
    }

    @Test("A Journal migrated to v28 with NO Outbox rows gets a fresh salt after v29 runs")
    func journalWithoutOutboxRowGetsFreshSalt() throws {
        let fixture = try JournalFixture()
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: fixture.projectID)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let v28 = try DatabaseQueue(path: fileURL.path)
        try JournalMigrations.migrator.migrate(v28, upTo: "v28-night-opening-board-snapshot")

        let journal = try fixture.open()

        #expect(!journal.outboxSalt.isEmpty)
        #expect(UUID(uuidString: journal.outboxSalt) != nil)
    }
}
