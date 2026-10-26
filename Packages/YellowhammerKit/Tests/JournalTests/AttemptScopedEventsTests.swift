import Domain
import Foundation
import Testing

@testable import Journal

@Test("events(ofTypes:cardID:attemptID:) returns only the asked types of the asked Attempt, in append order")
func attemptScopedEventsFilterInSQL() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    func spawned(_ card: Int64, _ attempt: Int64) -> JournalEvent {
        .agentCLIProcessSpawned(cardID: card, issueID: "X", attemptID: attempt, pass: .worker, cli: "claude")
    }
    func capture(_ record: String, _ card: Int64, _ attempt: Int64) -> JournalEvent {
        .promptCaptureRequested(
            recordID: record, pass: .worker, cardID: card, issueID: "X", attemptID: attempt, round: 1, ordinal: nil
        )
    }
    try journal.append(spawned(1, 1))
    try journal.append(capture("rec-other-attempt", 1, 2))
    try journal.append(capture("rec-other-card", 2, 1))
    try journal.append(capture("rec-mine", 1, 1))
    try journal.append(.rehearsalFixtureAnswered(cardID: 1, issueID: "X", attemptID: 1, pass: .worker, fixture: "f"))

    let events = try journal.events(
        ofTypes: [.promptCaptureRequested, .agentCLIProcessSpawned], cardID: 1, attemptID: 1
    )

    #expect(events.map(\.type) == [.agentCLIProcessSpawned, .promptCaptureRequested])
    guard case .promptCaptureRequested(let recordID, _, _, _, _, _, _) = events[1].event else {
        Issue.record("expected the capture event")
        return
    }
    #expect(recordID == "rec-mine")
}
