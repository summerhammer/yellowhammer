import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// board-projection / operator-done, AC3: a Work Card the Operator moved to Done is Done, not Blocked, so the
// Pulse's Needs you does not list it.

private struct OperatorDonePulseFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-pulse-operator-done-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: "fixture"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

@Test("Needs you does not list a Card the Operator moved to Done, from Blocked or Waiting on You")
func needsYouOmitsOperatorDoneCards() throws {
    let fixture = try OperatorDonePulseFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: "F-1")
    let blocked = try insertCard(
        journal, cycleID: feature.cycleID, issueID: "C-1", state: .blocked, blockReason: .featureCompleted, order: 1
    )
    let waiting = try insertCard(journal, cycleID: feature.cycleID, issueID: "C-2", state: .waitingOnYou, order: 2)
    try insertCard(
        journal, cycleID: feature.cycleID, issueID: "C-3", state: .blocked, blockReason: .checkFailure, order: 3
    )
    let runID = RunID()
    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch)

    for id in [blocked, waiting] {
        _ = try journal.markCardOperatorDone(cardID: id, runID: runID, act: .author, nightID: nil, now: epoch)
    }

    let needsYou = try PulseSnapshot.read(from: journal, status: .idle).needsYou
    #expect(needsYou.cards.map(\.id) == ["C-3"])
}
