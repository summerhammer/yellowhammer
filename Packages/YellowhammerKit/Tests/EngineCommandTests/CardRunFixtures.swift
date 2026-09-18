import Domain
@testable import Engine
import Foundation
import Journal
import Synchronization
import Testing

// Shared by the Card run tests (roadmap P8.4): a Feature with Cards and Worktrees in the Journal, a
// Route to resolve, and fakes for the two seams the Card run calls — the Dispatch seam and the Check.

let cardRunOpus = Route(cli: "claude", model: "opus", effort: "high")!

func cardRunResolver(
    probe: @escaping RouteResolver.ProbeEligibility = { _ in .offered }, table: RoutingTable? = nil
) -> RouteResolver {
    let table = table ?? RoutingTable(entries: [RoutingEntry(kind: Kind("card")!, route: cardRunOpus)])
    return RouteResolver(table: table, probeEligibility: probe)
}

/// A Journal holding one in-flight Feature with Cards, a held Worktree per repository and this run's
/// Act-scoped Lease, and the build context a Card run is handed.
struct CardRunWorld {
    let journal: JournalStore
    let runID: RunID
    let cardIDs: [String: Int64]
    let context: BuildActContext
    let boards: NightCardTestBoards?

    func card(_ issueID: String) throws -> CardRecord {
        try journal.card(id: try #require(cardIDs[issueID]))
    }

    func attempts(_ issueID: String) throws -> [AttemptRecord] {
        try journal.attemptHistory(cardID: try #require(cardIDs[issueID])).attempts
    }
}

/// Each Card is `(issueID, repository)`. With `withBoard`, every Card has an issue on the in-memory
/// Linear stand-in and the Outbox is bound to it, so state transitions post to the board.
func makeCardRunWorld(
    journal: JournalStore, cards: [(issueID: String, repository: String)] = [("BACK-1", "backend")],
    withBoard: Bool = true, worktreePath: @escaping (String) -> String = { "/tmp/yh-cardrun-\($0)" }
) async throws -> CardRunWorld {
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal) else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
    try journal.recordFeatureBranch(featureID: featureID, branch: buildActBranch)
    let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
    var cardIDs: [String: Int64] = [:]
    for (issueID, repository) in cards {
        cardIDs[issueID] = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: issueID, repository: repository, state: .todo
        )
    }
    for repository in Set(cards.map(\.repository)).sorted() {
        try journal.recordWorktree(
            featureID: featureID, repository: repository, worktreeID: "wt-\(repository)",
            path: worktreePath(repository), runID: runID
        )
    }
    let night = try journal.openNight(nightStart: buildActNightStart, mode: .rehearsal, act: .build, runID: runID).night

    var boards: NightCardTestBoards?
    var actBoard: ActBoard?
    var outbox: Outbox?
    if withBoard {
        let made = try await makeBuildActBoards()
        for (issueID, _) in cards {
            await made.writing.seed(issue: issueID, description: nil)
        }
        boards = made
        actBoard = ActBoard(reading: FakeReadingBoard([page()]), writing: made.writing, provisioning: made.provisioning)
        outbox = Outbox(journal: journal, board: made.writing, runID: runID, act: .build, nightID: night.id)
    }
    let actContext = ActContext(
        act: .build, mode: .rehearsal, trigger: .scheduled, runID: runID, journal: journal, night: night,
        outbox: outbox, board: actBoard
    )
    let feature = try #require(try journal.inFlightFeature()).0
    let context = BuildActContext(
        act: actContext, feature: feature, cycleID: cycleID, reconciliation: WorktreeReconciliation(),
        deltaRead: nil
    )
    return CardRunWorld(journal: journal, runID: runID, cardIDs: cardIDs, context: context, boards: boards)
}

extension CardRun {
    /// Runs one Card of `world` as its Repo Lane would hand it over.
    func run(_ issueID: String, in world: CardRunWorld) async throws {
        let card = try world.card(issueID)
        let lane = RepoLane(repository: card.repository, cards: [card])
        try await run(
            card: card, in: lane, context: world.context,
            readiness: CardReadiness(brief: ArchitecturalBrief(prose: "", transcriptions: []), clauses: [])
        )
    }
}

/// The Card run's story as the event log tells it: each step, each state the Card moved to, each Attempt
/// ending, in order.
func cardRunLog(_ journal: JournalStore) throws -> [String] {
    try journal.events().compactMap { record in
        switch record.event {
        case .cardRunStep(_, _, let step, _): step.rawValue
        case .cardStateTransitioned(_, _, _, let to, _, _): "→ \(to.rawValue)"
        case .attemptEnded(_, _, _, _, let outcome, _): "attempt ended: \(outcome)"
        default: nil
        }
    }
}

/// An ordered record of what the Dispatch seam and the Check saw, shared by the fakes.
final class CallLog: Sendable {
    private let entries = Mutex<[String]>([])
    func add(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
}

/// The dispatch requests a fake saw, shared by reference between the copies of the struct that holds it.
final class RequestLog: Sendable {
    private let entries = Mutex<[AgentDispatchRequest]>([])
    func add(_ entry: AgentDispatchRequest) { entries.withLock { $0.append(entry) } }
    var all: [AgentDispatchRequest] { entries.withLock { $0 } }
    func passes(_ pass: RunPass) -> [AgentDispatchRequest] { all.filter { $0.pass == pass } }
}

/// A Dispatch seam that answers from ``RehearsalDispatch`` and records each pass; `during` runs inside a
/// pass, so a test can hold it open or interfere with the Card's Lease mid-run.
struct LoggingDispatch: AgentDispatch {
    let log: CallLog
    var script: [RunPass: RehearsalResultFixture] = [:]
    var during: (@Sendable (RunPass) async throws -> Void)?
    /// Every request seen, in order, so a test can inspect the instruction, Route, Worktree and Attempt.
    let requests = RequestLog()

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        log.add("dispatch \(request.pass.rawValue)")
        requests.add(request)
        try await during?(request.pass)
        return try await RehearsalDispatch(script: script).dispatch(request)
    }
}

/// A Dispatch seam whose Route cannot be run at all on this machine.
struct RefusingDispatch: AgentDispatch {
    let log: CallLog

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        log.add("dispatch \(request.pass.rawValue)")
        throw AgentDispatchRefusal(reason: "no CLI Adapter for `\(request.route.cli)`")
    }
}

/// A Check that answers from a scripted sequence of results, repeating the last one once it runs out.
final class RecordingCheck: RepositoryCheckRunning, Sendable {
    let log: CallLog
    private let results: [RepositoryCheckResult]
    private let calls = Mutex(0)

    convenience init(log: CallLog, result: RepositoryCheckResult = .declaredNone) {
        self.init(log: log, results: [result])
    }

    init(log: CallLog, results: [RepositoryCheckResult]) {
        self.log = log
        self.results = results
    }

    func run(repository: String, check: Check, worktreePath: String) async throws -> RepositoryCheckResult {
        log.add("check")
        let index = calls.withLock { calls in
            defer { calls += 1 }
            return calls
        }
        return results[min(index, results.count - 1)]
    }
}
