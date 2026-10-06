import Domain
@testable import Engine
import Foundation
import Journal
import Repositories
import Synchronization
import Testing

// roadmap P19.5 (Landing Edge Cases Ruling 2026-10-01, OQ106; Attempt, Block and Reset Ruling, OQ60): a
// worker's question puts its Card in Waiting on You, and the OQ60 sequence runs exactly as on Block, so
// neither the Worktree nor the Feature Branch keeps the asking Attempt's commits or edits when the lane's
// next Card dispatches. Run against a real git fixture and the real `AttemptWorktreeReset`; nothing here
// asserts anything a model wrote, only engine-written git state and Journal rows.

/// What one dispatched pass saw of the Worktree at the moment it was dispatched.
private struct SeenWorktree: Sendable {
    let issueID: String
    let pass: RunPass
    let head: String
    let status: String
    let wip: WIPContext?
}

/// Answers like ``RehearsalDispatch``, except BACK-1's first worker pass makes one commit in the Worktree
/// and leaves one further uncommitted edit before asking its question. Records the Worktree's `HEAD` and
/// `git status --porcelain` at every dispatch.
private final class AskingDispatch: AgentDispatch, Sendable {
    let path: String
    private let git = GitRunner()
    private let asked = Mutex(false)
    private let seenLog = Mutex<[SeenWorktree]>([])
    let workerCommit = Mutex<String?>(nil)

    init(path: String) { self.path = path }

    var seen: [SeenWorktree] { seenLog.withLock { $0 } }

    private func git(_ args: [String]) async -> String {
        await git.run(["-C", path] + args).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        let head = await git(["rev-parse", "HEAD"])
        let status = await git(["status", "--porcelain"])
        seenLog.withLock {
            $0.append(SeenWorktree(
                issueID: request.issueID, pass: request.pass, head: head, status: status,
                wip: request.instruction.cardInstruction?.payloads.wip
            ))
        }
        let firstAsk = request.issueID == "BACK-1" && request.pass == .worker
            && asked.withLock { asked in
                defer { asked = true }
                return !asked
            }
        guard firstAsk else { return try await RehearsalDispatch().dispatch(request) }

        try "the worker's commit".write(toFile: path + "/worker.txt", atomically: true, encoding: .utf8)
        _ = await git(["add", "worker.txt"])
        _ = await git(["commit", "-m", "feat: the worker's commit"])
        let commit = await git(["rev-parse", "HEAD"])
        workerCommit.withLock { $0 = commit }
        try "an uncommitted edit".write(toFile: path + "/base.txt", atomically: true, encoding: .utf8)
        return try await RehearsalDispatch(script: [.worker: .workerQuestion]).dispatch(request)
    }
}

private let branchName = buildActBranch.name

/// A repository with one base commit, on the Feature Branch the world records, so a WIP commit does not
/// refuse. Returns the base commit.
private func prepareRepository(_ repo: borrowing GateGitFixture) async throws -> String {
    await repo.initRepo()
    let base = try await repo.commit(filename: "base.txt", content: "base", message: "initial")
    await repo.run(["checkout", "-b", branchName])
    return base
}

private func recordKnownGood(_ commit: String, world: CardRunWorld) throws {
    let worktree = try #require(
        try world.journal.heldWorktree(featureID: world.context.feature.id, repository: "backend")
    )
    _ = try world.journal.recordWorktreeKnownGood(id: worktree.id, commit: commit, runID: world.runID)
}

private func makeRun(dispatch: any AgentDispatch) -> CardRun {
    CardRun(
        resolver: cardRunResolver(), dispatch: dispatch, check: RecordingCheck(log: CallLog()),
        checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 3,
        resetting: AttemptWorktreeReset()
    )
}

@Suite("A Card that asks is reset to last_known_good_commit (P19.5)")
struct CardRunQuestionResetTests {
    @Test("A Card that asks leaves no commits or edits on the branch")
    func askingLeavesNothingOnTheBranch() async throws {
        let repo = GateGitFixture(name: "question-reset-1-\(UUID().uuidString)")
        let base = try await prepareRepository(repo)
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(
            journal: try fixture.open(), cards: [("BACK-1", "backend"), ("BACK-2", "backend")],
            worktreePath: { _ in repo.path }
        )
        try recordKnownGood(base, world: world)
        let dispatch = AskingDispatch(path: repo.path)

        try await makeRun(dispatch: dispatch).run("BACK-1", in: world)

        let card = try world.card("BACK-1")
        #expect(card.state == .waitingOnYou)
        #expect(card.waitingReason == .question)
        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.result == "question")

        await #expect(repo.run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == base)
        await #expect(
            repo.run(["rev-parse", "refs/heads/\(branchName)"]).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines) == base
        )
        await #expect(repo.run(["status", "--porcelain"]).stdout.isEmpty)

        let ref = WorktreeCommitter.preservationRef(branch: buildActBranch, attemptID: attempt.id)
        let preserved = await repo.run(["rev-parse", ref]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!preserved.isEmpty)
        #expect(attempt.preservedRef == ref)
        #expect(attempt.preservedCommit == preserved)

        let worker = try #require(dispatch.workerCommit.withLock { $0 })
        let lineage = await repo.run(["rev-list", ref]).stdout
        #expect(lineage.contains(worker), "the preserved commit descends from the worker's commit")
        #expect(preserved != worker, "a WIP Commit sits on top of the worker's commit")
        await #expect(repo.run(["show", "\(ref):base.txt"]).stdout == "an uncommitted edit")

        let message = await repo.run(["log", "-1", "--format=%B", ref]).stdout
        #expect(message.contains("Yellowhammer-WIP: \(branchName)"))
        let author = await repo.run(["log", "-1", "--format=%an <%ae>", ref]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(author == "Yellowhammer <noreply@yellowhammer.dev>")
    }

    @Test("The lane's next Card dispatches from last_known_good_commit")
    func nextCardDispatchesFromKnownGood() async throws {
        let repo = GateGitFixture(name: "question-reset-2-\(UUID().uuidString)")
        let base = try await prepareRepository(repo)
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(
            journal: try fixture.open(), cards: [("BACK-1", "backend"), ("BACK-2", "backend")],
            worktreePath: { _ in repo.path }
        )
        try recordKnownGood(base, world: world)
        let dispatch = AskingDispatch(path: repo.path)
        let run = makeRun(dispatch: dispatch)

        try await run.run("BACK-1", in: world)
        try await run.run("BACK-2", in: world)

        let next = dispatch.seen.filter { $0.issueID == "BACK-2" }
        #expect(!next.isEmpty)
        #expect(next.allSatisfy { $0.head == base && $0.status.isEmpty })
        #expect(try world.card("BACK-2").state == .done)
    }

    @Test("The sequence is idempotent")
    func sequenceIsIdempotent() async throws {
        let repo = GateGitFixture(name: "question-reset-3-\(UUID().uuidString)")
        let base = try await prepareRepository(repo)
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open(), worktreePath: { _ in repo.path })
        try recordKnownGood(base, world: world)

        try await makeRun(dispatch: AskingDispatch(path: repo.path)).run("BACK-1", in: world)

        let attempt = try #require(try world.attempts("BACK-1").first)
        let ref = try #require(attempt.preservedRef)
        let commitBefore = await repo.run(["rev-parse", ref]).stdout
        let countBefore = await repo.run(["rev-list", "--count", ref]).stdout

        let again = await AttemptWorktreeReset().reset(
            worktreePath: repo.path, branch: buildActBranch, repository: "backend", attemptID: attempt.id,
            knownGood: base
        )

        #expect(again == .reset(preserved: nil))
        await #expect(repo.run(["rev-parse", ref]).stdout == commitBefore)
        await #expect(repo.run(["rev-list", "--count", ref]).stdout == countBefore)
        let preservedEvents = try world.journal.events(ofType: .attemptWorkPreserved).filter {
            guard case .attemptWorkPreserved(_, _, let attemptID, _, _, _) = $0.event else { return false }
            return attemptID == attempt.id
        }
        #expect(preservedEvents.count == 1)
    }

    @Test("The resumed dispatch carries the preserved ref as context, and starts from last_known_good_commit")
    func resumedDispatchCarriesThePreservedWork() async throws {
        let repo = GateGitFixture(name: "question-reset-4-\(UUID().uuidString)")
        let base = try await prepareRepository(repo)
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open(), worktreePath: { _ in repo.path })
        try recordKnownGood(base, world: world)
        let dispatch = AskingDispatch(path: repo.path)
        let run = makeRun(dispatch: dispatch)

        try await run.run("BACK-1", in: world)
        let asked = try #require(try world.attempts("BACK-1").first)
        let preservedCommit = try #require(asked.preservedCommit)

        // The Operator's answer moves the Card back to Ready, as WaitingOnYouReplies does.
        let cardID = try #require(world.cardIDs["BACK-1"])
        try world.journal.transitionCard(
            cardID: cardID, to: .todo, runID: world.runID, act: .build, nightID: world.context.act.night.id
        )
        let seenBefore = dispatch.seen.count

        try await run.run("BACK-1", in: world)

        let resumed = Array(dispatch.seen.dropFirst(seenBefore))
        #expect(!resumed.isEmpty)
        #expect(resumed.allSatisfy { $0.head == base && $0.status.isEmpty })
        #expect(resumed.allSatisfy { $0.wip?.commit == preservedCommit })

        let history = try world.attempts("BACK-1")
        #expect(history.count == 2)
        #expect(history[0].result == "question")
        #expect(history[0].rounds.isEmpty)
        #expect(try world.journal.excludedRoutes(cardID: cardID).isEmpty)
        #expect(try world.card("BACK-1").state == .done)
    }
}
