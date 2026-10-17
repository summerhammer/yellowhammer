import Domain
@testable import Engine
import Foundation
@testable import Journal
@testable import Pulse
import Testing

// The Night Card's exceptions and the app's Night account are two renderings of the same Journal. An event
// the Card lists as an exception that the account does not flag as a problem leaves the Operator reading a
// clean account beside a Night Card that says otherwise (#533), so the two lists must not drift.

private let driftNight = nightCardNightStart

@Suite("Night Card exceptions are problems in the Night's account (#533)")
struct NightCardExceptionsAreProblemsTests {
    /// One event of each type the Night Card renders as an exception line, by payload.
    private static let exceptionEvents: [(label: String, event: JournalEvent)] = [
        (
            "boardWriteFailed",
            .boardWriteFailed(clientID: UUID(), operation: "updateIssue", issueID: "CARD-1", reason: "no")
        ),
        ("rateBudgetExhausted", .rateBudgetExhausted(degradation: "reads only")),
        ("mainlineFetchFailed", .mainlineFetchFailed(repository: "backend", reason: "offline")),
        ("absentNightDetected", .absentNightDetected(nightStart: driftNight)),
        ("notificationDeliveryFailed", .notificationDeliveryFailed(notification: "morning", reason: "denied")),
        ("worktreeNameCollision", .worktreeNameCollision(repository: "backend", requested: "a", reported: "b")),
        ("featureAuthoringFailed", .featureAuthoringFailed(name: "Feature", groupKey: "authoring:F:0", reason: "no")),
        ("featureBreakdownRejected", .featureBreakdownRejected(name: "Feature", reason: "over budget")),
        ("featureSelectionFailed", .featureSelectionFailed(reason: "no Feature fits"))
    ]

    @Test("Every event the Night Card renders as an exception is a problem in the Night's account")
    func everyExceptionIsAProblem() async throws {
        for (label, event) in Self.exceptionEvents {
            let fixture = try NightCardJournalFixture()
            let journal = try fixture.open()
            let boards = try await makeBoards()
            let board = ActBoard(
                reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning
            )
            try await EngineInvocation(
                act: .author, mode: .real, nightStart: driftNight, journal: journal,
                trigger: .forced, runID: RunID(), board: board,
                work: { context in
                    try journal.append(event, act: context.act, runID: context.runID, nightID: context.night.id)
                }
            ).run()
            let night = try #require(try journal.currentNight())

            let lines = try NightSummary.exceptionLines(night: night, journal: journal)
            // Authoring faults sit under the Night Card's Authoring heading, the rest under Exceptions.
            let rendered = !lines.isEmpty || NightCardMaintenance.authoringLine(for: event) != nil
            #expect(rendered, "\(label) is not rendered as an exception")
            let record = try #require(try journal.events(ofType: event.type).first)
            #expect(NightAccount.isProblem(record), "\(label) is an exception on the Night Card but not a problem")
        }
    }

    @Test("A per-Route rejection is no exception and no problem: only the fault it folds into is")
    func routeRejectionIsNotAProblem() async throws {
        let event = JournalEvent.authoringRouteRejected(
            pass: .breakdown, route: "claude/fable/high", ordinal: 1, cause: .unavailable, reason: "no"
        )
        #expect(NightCardMaintenance.authoringLine(for: event) == nil)
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        try journal.append(event, act: .author, runID: RunID(), nightID: nil)
        let record = try #require(try journal.events(ofType: .authoringRouteRejected).first)
        #expect(!NightAccount.isProblem(record))
    }
}
