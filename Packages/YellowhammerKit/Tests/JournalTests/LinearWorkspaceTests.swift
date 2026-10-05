import Domain
import Foundation
import Testing

@testable import Journal

struct LinearWorkspaceTests {
    private func tempHome() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yellowhammer-tests-\(UUID().uuidString)")
    }

    @Test
    func createdJournalHoldsTheWorkspaceAndKeepsIt() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let projectID = try #require(ProjectID(rawValue: "workspace-test"))
        let workspaceX = BoardObjectID(rawValue: "workspace-x")
        let workspaceY = BoardObjectID(rawValue: "workspace-y")
        let fileURL = JournalStore.defaultFileURL(homeDirectory: home, id: projectID)

        do {
            let created = try JournalStore.open(at: fileURL, projectID: projectID, linearWorkspace: workspaceX)
            #expect(created.linearWorkspace == workspaceX)
            #expect(try created.appliedMigrations() == ["journal-schema-4"])
        }
        #expect(JournalStore.migrationIdentifiers == ["journal-schema-4"])

        do {
            let readOnly = try JournalStore.openReadOnly(at: fileURL, projectID: projectID)
            #expect(readOnly.linearWorkspace == workspaceX)
        }

        let reopened = try JournalStore.open(at: fileURL, projectID: projectID, linearWorkspace: workspaceY)
        #expect(reopened.linearWorkspace == workspaceX)
    }

    @Test
    func openExistingOfAMissingJournalThrowsAndCreatesNothing() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let projectID = try #require(ProjectID(rawValue: "existing-test"))
        let configurationDirectory = home.appending(component: ".config", directoryHint: .isDirectory)
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: projectID)

        var error: JournalError?
        do {
            _ = try JournalStore.openExisting(configurationDirectory: configurationDirectory, projectID: projectID)
        } catch let journalError as JournalError {
            error = journalError
        }

        #expect(error == .missing(path: fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test
    func openExistingOpensAnExistingJournal() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let projectID = try #require(ProjectID(rawValue: "existing-ok-test"))
        let configurationDirectory = home.appending(component: ".config", directoryHint: .isDirectory)
        _ = try JournalStore.open(
            configurationDirectory: configurationDirectory, projectID: projectID,
            linearWorkspace: BoardObjectID(rawValue: "workspace-x")
        )

        let journal = try JournalStore.openExisting(
            configurationDirectory: configurationDirectory, projectID: projectID
        )

        #expect(journal.linearWorkspace == BoardObjectID(rawValue: "workspace-x"))
    }
}
