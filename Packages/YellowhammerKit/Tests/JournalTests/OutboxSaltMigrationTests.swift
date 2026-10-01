import Domain
import Foundation
import Testing

@testable import Journal

// The rehearsal cleanup deletes a Project's Journal and archives its Linear issues; a re-run then
// computed the same deterministic Outbox client id, matched the archived issue, and wrote invisibly
// into it. `project_state.outbox_salt` salts every id this Journal computes with a value fixed for its life, so a
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

@Suite("The Outbox salt")
struct OutboxSaltMigrationTests {
    @Test("A freshly created Journal has a non-empty, lowercased-UUID outbox_salt")
    func freshJournalHasParseableSalt() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()

        #expect(!journal.outboxSalt.isEmpty)
        #expect(UUID(uuidString: journal.outboxSalt) != nil)
        #expect(journal.outboxSalt == journal.outboxSalt.lowercased())
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
}
