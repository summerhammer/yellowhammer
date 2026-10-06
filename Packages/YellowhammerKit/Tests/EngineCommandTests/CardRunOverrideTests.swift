import Domain
@testable import Engine
import Foundation
import Journal
import Synchronization
import Testing

// Override Ruling (OQ126), end to end through the Card run: a Card whose `Override` label names a Route
// that fails its Route Pre-flight is a Readiness Check failure — nothing dispatched, no Attempt, and the
// reason posted on the Card.

/// A pre-flight that fails every Route, counting what it was asked.
private final class RejectingPreflight: RoutePreflighting {
    let asked = Mutex<[Route]>([])

    func preflight(_ route: Route, runID: RunID) async throws -> RoutePreflightVerdict {
        asked.withLock { $0.append(route) }
        return .failed(reason: "`\(route.cli)` rejected model `\(route.model)`")
    }
}

/// `world` with the team's `Override` group holding `label`, and the Delta Read having seen its Card
/// carry that label.
private func pinning(_ label: String, on issueID: String, in world: CardRunWorld) async throws -> BuildActContext {
    let boards = try #require(world.boards)
    let group = try await boards.provisioning.createLabel(name: "Override", team: teamID, isGroup: true, parent: nil)
    _ = try await boards.provisioning.createLabel(name: label, team: teamID, isGroup: false, parent: group.id)
    let card = try world.card(issueID)
    let object = BoardObject(
        id: BoardObjectID(rawValue: issueID), key: issueID, title: "A Card", description: nil,
        workflowState: BoardWorkflowState(id: BoardObjectID(rawValue: "state-todo"), name: "Todo"),
        labels: ["Card", label], parent: nil, url: "https://linear.app/x/\(issueID)",
        createdAt: Date(), updatedAt: Date()
    )
    let change = CardChange(
        card: card, object: object, stateDiffers: false, managedBlockEdited: nil, proseEdited: nil,
        delimitersBroken: nil, repositoryOnBoard: nil
    )
    let report = DeltaReadReport(since: nil, syncPoint: nil, requests: 1, cardChanges: [change])
    let context = world.context
    return BuildActContext(
        act: context.act, feature: context.feature, cycleID: context.cycleID,
        reconciliation: context.reconciliation, deltaRead: report
    )
}

@Suite("Card run: a Card override's Route Pre-flight")
struct CardRunOverrideTests {
    @Test("A Route that fails its pre-flight dispatches nothing, records no Attempt, and says why on the Card")
    func failedPreflightIsReportedOnTheCard() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let context = try await pinning("agy/opus/max", on: "BACK-1", in: world)
        let preflight = RejectingPreflight()
        let log = CallLog()
        let rehearsal = RehearsalDispatch()
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: rehearsal, check: RecordingCheck(log: log),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3,
            resetting: RecordingAttemptResetting(), preflighting: preflight
        )

        let card = try world.card("BACK-1")
        try await run.run(
            card: card, in: RepoLane(repository: card.repository, cards: [card]), context: context,
            readiness: CardReadiness(brief: ArchitecturalBrief(prose: "", transcriptions: []), clauses: [])
        )

        #expect(preflight.asked.withLock { $0 } == [Route(cli: "agy", model: "opus", effort: "max")!])
        #expect(rehearsal.answered.isEmpty)
        #expect(try world.attempts("BACK-1").isEmpty)
        #expect(try world.card("BACK-1").state == .todo)
        let comments = await try #require(world.boards).writing.comments
        #expect(comments.count == 1)
        #expect(comments.first?.issue == BoardObjectID(rawValue: "BACK-1"))
        #expect(comments.first?.body.contains("`agy` rejected model `opus`") == true)
        #expect(comments.first?.body.contains("consumed no Attempt") == true)
    }
}
