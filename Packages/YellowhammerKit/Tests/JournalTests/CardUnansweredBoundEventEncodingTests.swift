import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// The Card unanswered-Nights bound's own event (roadmap P11.4; spec: bounds/bound-unanswered-nights),
// round-tripped the same way the Refusal clock's `refusalExpired` is in RefusalEventEncodingTests.swift.

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
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

@Test("cardUnansweredBoundFired event round-trips with an `reply overdue` Block Reason")
func cardUnansweredBoundFiredRoundTripsUnanswered() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .cardUnansweredBoundFired(
            cardID: 1, issueID: "BACK-1", unansweredNights: 2, bound: 1, blockReason: "reply overdue"
        ),
        act: .build, runID: run, now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .cardUnansweredBoundFired(
        let cardID, let issueID, let unansweredNights, let bound, let blockReason
    ) = records[0].event else {
        Issue.record("Event is not cardUnansweredBoundFired")
        return
    }
    #expect(cardID == 1)
    #expect(issueID == "BACK-1")
    #expect(unansweredNights == 2)
    #expect(bound == 1)
    #expect(blockReason == "reply overdue")
}

@Test("cardUnansweredBoundFired event round-trips with an `decision overdue` Block Reason")
func cardUnansweredBoundFiredRoundTripsUndecided() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .cardUnansweredBoundFired(
            cardID: 2, issueID: "BACK-2", unansweredNights: 2, bound: 1, blockReason: "decision overdue"
        ),
        act: .build, runID: run, now: epoch
    )
    let records = try journal.events()

    guard case .cardUnansweredBoundFired(_, _, _, _, let blockReason) = records[0].event else {
        Issue.record("Event is not cardUnansweredBoundFired")
        return
    }
    #expect(blockReason == "decision overdue")
}
