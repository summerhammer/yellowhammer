import Domain
@testable import Engine
import Foundation
@testable import Journal
import Synchronization
import Testing

// roadmap P10.5: shared fixtures for the Verification tests. Only wiring, routing and arithmetic are
// scripted here — a stub verifier answers with fixed verdicts, and no test asserts that any verdict a
// model would reach is right.

let routeWriter = Route(cli: "claude", model: "opus", effort: "high")!
let routeOther = Route(cli: "codex", model: "gpt-5.4", effort: "high")!
let routeThird = Route(cli: "gemini", model: "pro", effort: "high")!

/// What a scripted Route does when the verifier is dispatched to it.
enum VerifierBehaviour {
    case refuse
    case exit(Int32)
    case crash
    /// Judges every clause the request names `met` (or, for those in `unmet`, `unmet`).
    case judgeAll(unmet: Set<String> = [])
    /// Answers with a fixed result whatever was asked.
    case answer(DispatchResult)
}

/// An `AgentDispatch` answering per Route and recording every request in order.
final class ScriptedVerifierDispatch: AgentDispatch, Sendable {
    private let behaviours: [Route: VerifierBehaviour]
    private let log = Mutex<[AgentDispatchRequest]>([])

    init(_ behaviours: [Route: VerifierBehaviour]) {
        self.behaviours = behaviours
    }

    var requests: [AgentDispatchRequest] { log.withLock { $0 } }

    /// The clauses each request named, as `<issue> <cid>`.
    var dispatchedClauses: [[String]] {
        requests.compactMap { request in
            guard case .verification(let instruction) = request.instruction else { return nil }
            return instruction.clauses.map { "\($0.issueID) \($0.cid)" }
        }
    }

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        log.withLock { $0.append(request) }
        switch behaviours[request.route] ?? .refuse {
        case .refuse:
            throw AgentDispatchRefusal(reason: "no executable")
        case .exit(let status):
            return AgentDispatchReport(outcome: .failed(exitStatus: status))
        case .crash:
            return AgentDispatchReport(outcome: .crashedUnknown(.signaled(9)))
        case .answer(let result):
            return AgentDispatchReport(outcome: .completed(result))
        case .judgeAll(let unmet):
            guard case .verification(let instruction) = request.instruction else {
                preconditionFailure("a verifier request carries a verification instruction")
            }
            let clauses = instruction.clauses.map {
                VerifiedClause(
                    cid: $0.cid, issueID: $0.issueID,
                    verdict: unmet.contains("\($0.issueID) \($0.cid)") ? .unmet : .met,
                    whatWasChecked: "scripted check of \($0.cid)", interpretation: "scripted reading of \($0.cid)"
                )
            }
            let result = VerifierResult(outcome: .reported(clauses: clauses))
            return AgentDispatchReport(outcome: .completed(.verifier(result)))
        }
    }
}

func verificationFeature(_ resolver: RouteResolver? = nil) -> RouteResolver {
    resolver ?? verificationResolver(primary: routeOther, fallbacks: [routeThird])
}

func verificationResolver(primary: Route, fallbacks: [Route] = []) -> RouteResolver {
    let table = RoutingTable(entries: [RoutingEntry(kind: .authoring, route: primary, fallbacks: fallbacks)])
    return RouteResolver(table: table) { _ in .offered }
}

/// One Card of a ``VerificationWorld``.
struct VerificationCard {
    let issue: String
    let repository: String
    let state: CardState

    init(_ issue: String, _ repository: String, _ state: CardState) {
        self.issue = issue
        self.repository = repository
        self.state = state
    }
}

/// A Feature → Cycle → Cards world for one Verification, on a real Journal and a fake board.
final class VerificationWorld {
    let fixture: OutboxJournalFixture
    let journal: JournalStore
    let board = FakeWritingBoard()
    let featureContext: LandActFeatureContext
    let cycleID: Int64
    let featureID: Int64

    /// `cards`: `(issue id, repository, state)`. Clauses are added afterwards with ``addClause``.
    init(
        cards: [VerificationCard] = [VerificationCard("BACK-1", "backend", .done)],
        repositories: ProjectRepositories? = selectionRepositories(),
        mode: NightMode = .real
    ) async throws {
        fixture = try OutboxJournalFixture()
        journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID, mode: mode)
        featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordFeatureBranch(featureID: featureID, branch: landBranch)
        cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        for card in cards {
            try insertReconcilerCard(
                journal, cycleID: cycleID, issueID: card.issue, repository: card.repository, state: card.state
            )
        }
        let night = try journal.openNight(nightStart: landNightStart, mode: mode, act: .land, runID: runID).night
        await board.seed(issue: "FEAT-1", description: nil)
        let outbox = Outbox(journal: journal, board: board, runID: runID, act: .land, clock: { landEpoch })
        let context = ActContext(
            act: .land, mode: mode, trigger: .scheduled, runID: runID, journal: journal, night: night,
            outbox: outbox, mainlines: selectionMainlines(), repositories: repositories
        )
        let (feature, _) = try #require(try journal.inFlightFeature())
        featureContext = LandActFeatureContext(act: context, feature: feature, cycleID: cycleID)
    }

    func addClause(
        issue: String, cid: String, text: String? = nil, location: String = "resolvable/story",
        provenance: String = "machine-found", level: String? = nil
    ) throws {
        try journal.insertClause(JournalStore.NewClause(
            cid: cid, issueID: issue, level: level ?? (issue == "FEAT-1" ? "feature" : "card"),
            text: text ?? "Clause \(cid) of \(issue).", locationID: location, provenance: provenance,
            citationProvenance: provenance
        ))
    }

    /// Records that `route` ran an Attempt of the Card — the code Verification judges was written on it.
    func addAttempt(card issue: String, route: Route) throws {
        let cardID = try #require(try journal.card(issueID: issue)).id
        try journal.write { db in
            try db.execute(
                sql: """
                INSERT INTO attempt (card_id, budget_epoch, route_cli, route_model, route_effort, started_at)
                VALUES (?, 0, ?, ?, ?, ?)
                """,
                arguments: [cardID, route.cli, route.model, route.effort, JournalStore.timestamp(landEpoch)]
            )
        }
    }

    func verification(
        resolver: RouteResolver, dispatch: any AgentDispatch,
        citations: any CitationResolving = FakeCitationResolver()
    ) -> FeatureVerification {
        FeatureVerification(resolver: resolver, dispatch: dispatch, citations: citations)
    }
}
