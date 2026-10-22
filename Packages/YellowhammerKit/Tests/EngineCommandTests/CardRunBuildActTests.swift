import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Synchronization
import Testing

// roadmap P8.4 through the build Act: a fixture Feature with two Repo Lanes, each Card run from Ready to
// Done by the Card run over rehearsal result fixtures, on the Worktree its own lane holds.

private final class StackingLaneDispatch: AgentDispatch, Sendable {
    let worktreePath: String
    let failWorkerIssues: Set<String>
    private let git = GitRunner()
    private let commitsByIssue = Mutex<[String: String]>([:])
    let requests = RequestLog()

    init(worktreePath: String, failWorkerIssues: Set<String> = []) {
        self.worktreePath = worktreePath
        self.failWorkerIssues = failWorkerIssues
    }

    func commit(for issueID: String) -> String? {
        commitsByIssue.withLock { $0[issueID] }
    }

    private func runGit(_ args: [String]) async -> String {
        await git.run(["-C", worktreePath] + args).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        requests.add(request)
        if request.pass == .worker {
            let file = "\(worktreePath)/\(request.issueID).txt"
            try "work for \(request.issueID)".write(toFile: file, atomically: true, encoding: .utf8)
            _ = await runGit(["add", "\(request.issueID).txt"])
            _ = await runGit(["commit", "-m", "feat: \(request.issueID)"])
            let sha = await runGit(["rev-parse", "HEAD"])
            commitsByIssue.withLock { $0[request.issueID] = sha }
            if failWorkerIssues.contains(request.issueID) {
                return try await RehearsalDispatch(script: [.worker: .workerFailed]).dispatch(request)
            }
        }
        return try await RehearsalDispatch().dispatch(request)
    }
}

private struct BackendLaneRun {
    let journal: JournalStore
    let git: GitRunner
    let worktreeURL: URL
    let worktreePath: String
    let initialBase: String
    let world: CardRunWorld
    let dispatch: StackingLaneDispatch
}

private func runBackendLaneBuildAct(
    fixture: borrowing OutboxJournalFixture, failWorkerIssues: Set<String> = [], attemptsPerWorkCard: Int = 3
) async throws -> BackendLaneRun {
    let journal = try fixture.open()
    let git = GitRunner()
    let worktreeURL = fixture.directory.appending(component: "worktrees/backend", directoryHint: .isDirectory)
    let initialBase = try await initReconcilerGitRepo(at: worktreeURL, git: git, branch: buildActBranch.name)
    let worktreePath = worktreeURL.path(percentEncoded: false)
    let world = try await makeCardRunWorld(
        journal: journal, cards: [("BACK-1", "backend"), ("BACK-2", "backend")],
        worktreePath: { _ in worktreePath }
    )
    let held = try #require(try journal.heldWorktree(featureID: world.context.feature.id, repository: "backend"))
    _ = try journal.recordWorktreeKnownGood(id: held.id, commit: initialBase, runID: world.runID)

    let dispatch = StackingLaneDispatch(worktreePath: worktreePath, failWorkerIssues: failWorkerIssues)
    let run = CardRun(
        resolver: cardRunResolver(), dispatch: dispatch, check: RecordingCheck(log: CallLog()),
        checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: attemptsPerWorkCard,
        passTimeoutMinutes: 60, resetting: AttemptWorktreeReset()
    )
    let board = try #require(world.context.act.board)
    let invocation = EngineInvocation(
        act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
        trigger: .scheduled, runID: world.runID, board: board, workspace: ReconcilerFakeWorkspace(),
        work: BuildAct(cardRunner: run).work
    )
    try await invocation.run()
    return BackendLaneRun(
        journal: journal, git: git, worktreeURL: worktreeURL, worktreePath: worktreePath,
        initialBase: initialBase, world: world, dispatch: dispatch
    )
}

@Suite("Card run in the build Act")
struct CardRunBuildActTests {
    @Test("A rehearsal build Act runs both Repo Lanes' Cards from Ready to Done, one Worktree per lane")
    func rehearsalBuildActRunsTwoLanesToDone() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let git = GitRunner()
        let worktrees = fixture.directory.appending(component: "worktrees", directoryHint: .isDirectory)
        for repository in ["backend", "mobile"] {
            try await initReconcilerGitRepo(
                at: worktrees.appending(component: repository), git: git, branch: buildActBranch.name
            )
        }
        let world = try await makeCardRunWorld(
            journal: journal, cards: [("BACK-1", "backend"), ("BACK-2", "backend"), ("MOB-1", "mobile")],
            worktreePath: { worktrees.appending(component: $0).path(percentEncoded: false) }
        )
        let rehearsal = RehearsalDispatch()
        let log = CallLog()
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: rehearsal, check: RecordingCheck(log: log),
            checks: ["backend": .none, "mobile": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 3,
            passTimeoutMinutes: 60,
            resetting: RecordingAttemptResetting()
        )
        let board = try #require(world.context.act.board)
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: world.runID, board: board, workspace: ReconcilerFakeWorkspace(),
            work: BuildAct(cardRunner: run).work
        )

        try await invocation.run()

        for issueID in ["BACK-1", "BACK-2", "MOB-1"] {
            #expect(try world.card(issueID).state == .done)
            let attempt = try #require(try world.attempts(issueID).first)
            #expect(attempt.result == "success")
        }
        // Each Card ran all three passes and the Check, in that order, in its own lane's Worktree.
        #expect(rehearsal.answered.count == 9)
        #expect(log.all == Array(repeating: "check", count: 3))
        for request in rehearsal.answered {
            let repository = try #require(request.issueID.hasPrefix("BACK") ? "backend" : "mobile")
            #expect(request.worktreePath == worktrees.appending(component: repository).path(percentEncoded: false))
        }
        // Within the backend lane, BACK-1 finished before BACK-2 began.
        let backend = rehearsal.answered.filter { $0.issueID.hasPrefix("BACK") }.map(\.issueID)
        #expect(backend == ["BACK-1", "BACK-1", "BACK-1", "BACK-2", "BACK-2", "BACK-2"])
        #expect(try journal.events(ofType: .repoLaneEnded).count == 2)
        #expect(try journal.currentActLease() == nil)
    }

    @Test("Sequential Cards in a RepoLane advance lastKnownGoodCommit and thread LaneStackContext across passes")
    func sequentialCardsAdvanceKnownGoodAndThreadLaneStackContext() async throws {
        let fixture = try OutboxJournalFixture()
        let outcome = try await runBackendLaneBuildAct(fixture: fixture)
        let c1 = try #require(outcome.dispatch.commit(for: "BACK-1"))
        let c2 = try #require(outcome.dispatch.commit(for: "BACK-2"))
        #expect(c1 != outcome.initialBase)
        #expect(c2 != c1)

        let back1Requests = outcome.dispatch.requests.all.filter { $0.issueID == "BACK-1" }
        #expect(back1Requests.map(\.pass) == [.architect, .worker, .reviewer])
        for request in back1Requests where request.pass != .reviewer {
            let stack = try #require(request.instruction.cardInstruction?.laneStack)
            #expect(stack == LaneStackContext(
                baseCommit: outcome.initialBase, judgedCommit: nil, completedEarlierCards: []
            ))
        }
        let back1Reviewer = try #require(back1Requests.last?.instruction.cardInstruction)
        #expect(
            back1Reviewer.laneStack == LaneStackContext(
                baseCommit: outcome.initialBase, judgedCommit: c1, completedEarlierCards: []
            )
        )
        #expect(back1Reviewer.render().contains("Judge the changes in `\(outcome.initialBase)..\(c1)`"))

        let back2Requests = outcome.dispatch.requests.all.filter { $0.issueID == "BACK-2" }
        #expect(back2Requests.map(\.pass) == [.architect, .worker, .reviewer])
        let expectedEarlier = [LaneCompletedCard(key: "BACK-1", title: "BACK-1")]
        for request in back2Requests where request.pass != .reviewer {
            let instruction = try #require(request.instruction.cardInstruction)
            #expect(
                instruction.laneStack == LaneStackContext(
                    baseCommit: c1, judgedCommit: nil, completedEarlierCards: expectedEarlier
                )
            )
            #expect(instruction.render().contains("Build on top of `\(c1)`"))
        }
        let back2Reviewer = try #require(back2Requests.last?.instruction.cardInstruction)
        #expect(
            back2Reviewer.laneStack == LaneStackContext(
                baseCommit: c1, judgedCommit: c2, completedEarlierCards: expectedEarlier
            )
        )
        #expect(back2Reviewer.render().contains("Judge the changes in `\(c1)..\(c2)`"))

        let updatedWorktree = try #require(
            try outcome.journal.heldWorktree(featureID: outcome.world.context.feature.id, repository: "backend")
        )
        #expect(updatedWorktree.lastKnownGoodCommit == c2)
        #expect(try outcome.journal.commitsRecordedMissingTrailer(cardID: try outcome.world.card("BACK-1").id) == [c1])
        #expect(try outcome.journal.commitsRecordedMissingTrailer(cardID: try outcome.world.card("BACK-2").id) == [c2])
    }

    @Test("When a later Card in a RepoLane fails, Worktree reset rewinds to the earlier Card's commit")
    func laterCardFailureResetsWorktreeToEarlierCompletedCardCommit() async throws {
        let fixture = try OutboxJournalFixture()
        let outcome = try await runBackendLaneBuildAct(
            fixture: fixture, failWorkerIssues: ["BACK-2"], attemptsPerWorkCard: 1
        )
        let c1 = try #require(outcome.dispatch.commit(for: "BACK-1"))
        let c2Failed = try #require(outcome.dispatch.commit(for: "BACK-2"))
        #expect(try outcome.world.card("BACK-1").state == .done)
        #expect(try outcome.world.card("BACK-2").state == .blocked)

        let headAfterReset = await reconcilerRevParse("HEAD", in: outcome.worktreeURL, git: outcome.git)
        #expect(headAfterReset == c1)
        #expect(headAfterReset != outcome.initialBase)
        #expect(headAfterReset != c2Failed)
        #expect(FileManager.default.fileExists(atPath: "\(outcome.worktreePath)/BACK-1.txt"))
        #expect(!FileManager.default.fileExists(atPath: "\(outcome.worktreePath)/BACK-2.txt"))

        let updatedWorktree = try #require(
            try outcome.journal.heldWorktree(featureID: outcome.world.context.feature.id, repository: "backend")
        )
        #expect(updatedWorktree.lastKnownGoodCommit == c1)
        let back2Attempt = try #require(try outcome.world.attempts("BACK-2").first)
        #expect(back2Attempt.preservedCommit == c2Failed)
        let preservedEvent = try #require(outcome.journal.events(ofType: .attemptWorkPreserved).first)
        guard case .attemptWorkPreserved(_, _, let attemptID, _, let preserved, let resetTo) = preservedEvent.event
        else {
            Issue.record("expected attemptWorkPreserved event")
            return
        }
        #expect(attemptID == back2Attempt.id)
        #expect(preserved == c2Failed)
        #expect(resetTo == c1)
    }
}
