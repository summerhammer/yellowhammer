import Domain
import Foundation
import GRDB
@testable import Journal
import Testing

@Suite("Project removal's transaction boundary")
struct ProjectRemovalTransactionTests {
    @Test("Removal excludes an overlapping Act and removal without an Act lease or committed Journal mutation")
    func excludesOtherWriters() throws {
        let directory = FileManager.default.temporaryDirectory.appending(component: "yh-removal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectID = try #require(ProjectID(rawValue: "alpha"))
        let source = try JournalStore.open(configurationDirectory: directory, projectID: projectID)
        let other = try JournalStore.openExisting(configurationDirectory: directory, projectID: projectID)
        let run = RunID()
        let removal = try source.beginProjectRemoval(runID: run)
        defer { removal.rollbackProjectRemoval() }
        #expect(try source.currentActLease() == nil)
        #expect(throws: ProjectRemovalHoldError.self) {
            try other.claimActLease(act: .author, runID: RunID(), mode: .real)
        }
        #expect(throws: ProjectRemovalHoldError.self) { try other.beginProjectRemoval(runID: RunID()) }
        #expect(try source.events().isEmpty)
        removal.rollbackProjectRemoval()
        #expect(throws: ProjectRemovalTransactionError.self) { try removal.revalidateProjectRemoval(runID: run) }
        guard case .claimed = try other.claimActLease(act: .author, runID: RunID(), mode: .real) else {
            Issue.record("the removal writer lock should have been released")
            return
        }
    }

    @Test("Outbox evidence and lifecycle recording become visible together only on removal commit")
    func evidenceCommitsAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appending(component: "yh-removal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try JournalStore.open(configurationDirectory: directory,
            projectID: try #require(ProjectID(rawValue: "alpha")))
        let client = UUID()
        let run = RunID()
        let staged = try source.beginProjectRemoval(runID: run)
        defer { staged.rollbackProjectRemoval() }
        let entry = try #require(try staged.acceptOutbox([
            OutboxDraft(clientID: client, operation: "commentCreate", payload: "{}")
        ], runID: run).first)
        _ = try staged.markOutboxApplied(id: entry.id, result: "comment-id")
        _ = try staged.recordProjectRemoval(NewProjectRemoval(featureIssueID: nil, releasedWorktreeIDs: []), runID: run)
        #expect(try source.outboxEntry(clientID: client) == nil)
        #expect(try source.events().isEmpty)
        try staged.commitProjectRemoval()
        #expect(try source.outboxEntry(clientID: client)?.result == "comment-id")
        #expect(try source.events().map(\.type) == [.projectRemoved])
        #expect(throws: ProjectRemovalTransactionError.self) { try staged.revalidateProjectRemoval(runID: run) }
    }

    @Test("Failed removal rolls back Outbox attempts, receipts and events")
    func failureRollsBackEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appending(component: "yh-removal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try JournalStore.open(configurationDirectory: directory,
            projectID: try #require(ProjectID(rawValue: "alpha")))
        let run = RunID()
        let staged = try source.beginProjectRemoval(runID: run)
        let entry = try #require(try staged.acceptOutbox([
            OutboxDraft(clientID: UUID(), operation: "commentCreate", payload: "{}")
        ], runID: run).first)
        _ = try staged.recordOutboxAttemptFailure(id: entry.id, error: "unreadable")
        _ = try staged.markOutboxApplied(id: entry.id, result: "comment-id")
        _ = try staged.recordProjectRemoval(NewProjectRemoval(featureIssueID: nil, releasedWorktreeIDs: []), runID: run)
        staged.rollbackProjectRemoval()
        #expect(try source.pendingOutboxEntries().isEmpty)
        #expect(try source.outboxEntry(id: entry.id) == nil)
        #expect(try source.events().isEmpty)
        #expect(try source.currentActLease() == nil)
    }
}
