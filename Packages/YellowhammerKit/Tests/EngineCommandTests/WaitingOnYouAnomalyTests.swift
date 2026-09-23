import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

// bounds/escalate-a-question-to-the-operator (last AC) and glossary → Waiting on You: a Card read in
// Waiting on You with no Journal record behind it — an unknown object, or a known Card whose Journal
// state is Waiting on You with no waiting reason recorded — is reported as an anomaly and never
// dispatched; a Card the board hand-moved to Waiting on You while the Journal disagrees stays the
// existing `restated` path and is not double-reported. The Night Card's completion lists each anomaly
// this Night's Delta Reads found.

private func anomalyObject(
    _ id: String, labels: [String] = ["Card"], state: BoardWorkflowState = stateWaiting
) -> BoardObject {
    BoardObject(
        id: BoardObjectID(rawValue: id), key: "ENG-\(id)", title: id, description: nil,
        workflowState: state, labels: labels, parent: nil, url: "https://linear.app/x/\(id)",
        createdAt: deltaEpoch, updatedAt: deltaEpoch.addingTimeInterval(10)
    )
}

@Suite("Waiting on You anomalies")
struct WaitingOnYouAnomalyTests {
    @Test("An unknown object labelled Card in Waiting on You is an anomaly and still an unknown object")
    func unknownObjectLabelledCard() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeReadingBoard([page(objects: [anomalyObject("unknown-1")])])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.anomalies.map(\.issueID) == ["unknown-1"])
        #expect(report.anomalies[0].cardID == nil)
        #expect(report.anomalousIssueIDs == ["unknown-1"])
        #expect(report.unknownObjects.map(\.id.rawValue) == ["unknown-1"])
        let events = try journal.events(ofType: .waitingOnYouUnbacked)
        #expect(events.count == 1)
        if case .waitingOnYouUnbacked(let issueID, let cardID, _)? = events.first?.event {
            #expect(issueID == "unknown-1")
            #expect(cardID == nil)
        } else {
            Issue.record("expected waitingOnYouUnbacked")
        }
    }

    @Test("An object not labelled Card in Waiting on You is not an anomaly")
    func unlabelledObjectIsNotAnAnomaly() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeReadingBoard([page(objects: [anomalyObject("feature-1", labels: ["Feature"])])])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.anomalies.isEmpty)
        #expect(try journal.events(ofType: .waitingOnYouUnbacked).isEmpty)
    }

    @Test("A known Card in Waiting on You with no waiting reason recorded is an anomaly naming the Card")
    func knownCardWithoutWaitingReason() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: .waitingOnYou)
        let board = FakeReadingBoard([page(objects: [
            object("card-1", state: stateWaiting, description: fenced(block: "brief"))
        ])])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.anomalies.map(\.issueID) == ["card-1"])
        #expect(report.anomalies[0].cardID == cardID)
        #expect(report.anomalousIssueIDs == ["card-1"])
        #expect(report.restated.isEmpty, "the board agrees with the Journal's state; nothing is restated")
    }

    @Test("A Card the board hand-moved to Waiting on You stays the restated path, not an anomaly")
    func handMovedCardIsRestatedNotAnomaly() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertCard(journal, issueID: "card-1", state: .todo)
        let board = FakeReadingBoard([page(objects: [
            object("card-1", state: stateWaiting, description: fenced(block: "brief"))
        ])])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.restated.map(\.card.issueID) == ["card-1"])
        #expect(report.anomalies.isEmpty)
        #expect(try journal.events(ofType: .waitingOnYouUnbacked).isEmpty)
    }

    // MARK: - Night Card

    @Test("NightCardBlock.completed renders an Anomalies section only when there are anomalies")
    func completedRendersAnomaliesSection() {
        let night = NightRecord(
            id: 1, projectID: ProjectID(rawValue: "fixture")!, nightStart: nightCardNightStart,
            mode: .real, state: .closed, nightCardIssueID: "NIGHT-1", openedAt: deltaEpoch,
            completedAt: deltaEpoch, closeReason: .nightEnd, verdict: nil, triagedAt: nil
        )

        let withoutAnomalies = NightCardBlock.completed(night: night, projectID: night.projectID)
        #expect(!withoutAnomalies.contains("**Anomalies:**"))

        let withAnomalies = NightCardBlock.completed(
            night: night, projectID: night.projectID,
            anomalies: ["`ENG-1` was read in Waiting on You with no Journal record behind it; it was not dispatched."]
        )
        #expect(withAnomalies.contains("**Anomalies:**"))
        #expect(withAnomalies.contains("- `ENG-1` was read in Waiting on You"))
    }

    @Test("acceptCompletion lists each anomaly this Night's Delta Reads found, deduplicated")
    func acceptCompletionListsAnomalies() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let provisioning = boards.provisioning
        let writing = boards.writing
        let board = ActBoard(reading: FakeReadingBoard([]), writing: writing, provisioning: provisioning)

        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()

        let night = try #require(try journal.currentNight())
        let noise = RunID()
        try journal.append(
            .waitingOnYouUnbacked(issueID: "ENG-1", cardID: nil, reason: "read with no Journal record"),
            act: .author, runID: noise, nightID: night.id
        )
        // A duplicate of the same issue id, as a later Act's Delta Read of the same unbacked object
        // would produce: the rendered line must appear once.
        try journal.append(
            .waitingOnYouUnbacked(issueID: "ENG-1", cardID: nil, reason: "read with no Journal record"),
            act: .author, runID: noise, nightID: night.id
        )

        try await EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board, work: { _ in }
        ).run()

        let issue = try #require(await writing.liveIssues.first)
        let description = try #require(issue.description)
        #expect(description.contains("**Anomalies:**"))
        let line = "`ENG-1` was read in Waiting on You with no Journal record behind it; it was not dispatched."
        #expect(description.contains(line))
        #expect(description.components(separatedBy: line).count == 2, "the line must appear exactly once")
    }
}
