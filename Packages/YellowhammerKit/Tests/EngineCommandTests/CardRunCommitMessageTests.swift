import Domain
@testable import Engine
import Foundation
import Journal
import Synchronization
import Testing

// roadmap P19.4 (spec: graph-execution/run-a-card): the worker pass's instruction states the Project's
// `commit_message` Message Template rendered with the Card's tokens and asks for a `Yellowhammer-Card`
// trailer; after the worker reports a commit the engine records each commit missing that trailer, and
// the record never changes the Card's outcome. Nothing here asserts what a model wrote.

private let template = "{type}{scope}: {card_title} [{card_key}] {story} {repository}"

private func clause(_ cid: String, citing locationID: String) -> ClauseRecord {
    ClauseRecord(
        cid: cid, issueID: "BACK-1", level: "card", text: "t", locationID: locationID,
        provenance: "p", citationProvenance: "p", invalidated: false, deleted: false, createdAt: Date()
    )
}

private func boardObject(_ id: String, key: String, title: String) -> BoardObject {
    var made = object(id, title: title, state: stateTodo)
    made.key = key
    return made
}

private func readiness(_ clauses: [ClauseRecord]) -> CardReadiness {
    CardReadiness(brief: ArchitecturalBrief(prose: "", transcriptions: []), clauses: clauses)
}

@Suite("Card run, worker commit message and trailer record (P19.4)")
struct CardRunCommitMessageTests {
    private func makeRun(
        dispatch: any AgentDispatch, commitMessage: MessageTemplate = .default(.commitMessage),
        changeType: ChangeType = .feat
    ) -> CardRun {
        let log = CallLog()
        return CardRun(
            resolver: cardRunResolver(), dispatch: dispatch, check: RecordingCheck(log: log),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3,
            resetting: RecordingAttemptResetting(log: log), commitMessage: commitMessage, changeType: changeType
        )
    }

    private func run(
        _ cardRun: CardRun, in world: CardRunWorld, readiness: CardReadiness
    ) async throws {
        let card = try world.card("BACK-1")
        try await cardRun.run(
            card: card, in: RepoLane(repository: card.repository, cards: [card]), context: world.context,
            readiness: readiness
        )
    }

    /// Scripts the one board read `prepare` makes, so the Card and the Feature Issue are found by id.
    private func scriptBoard(_ world: CardRunWorld) async throws {
        let reading = try #require(world.context.act.board?.reading as? FakeReadingBoard)
        await reading.scriptObjectPages([
            .success(BoardPage(
                objects: [
                    boardObject("BACK-1", key: "YLH-7", title: "Fix login"),
                    boardObject("FEAT-1", key: "YLH-1", title: "Login Feature")
                ],
                nextCursor: nil
            ))
        ])
    }

    @Test("The worker instruction renders the template with the Card's tokens and asks for the trailer")
    func workerInstructionRendersTemplateAndTrailer() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        try await scriptBoard(world)
        let dispatch = LoggingDispatch(log: CallLog())
        let cardRun = makeRun(
            dispatch: dispatch, commitMessage: try MessageTemplate(template, kind: .commitMessage),
            changeType: try #require(ChangeType("fix"))
        )

        try await run(cardRun, in: world, readiness: readiness([
            clause("c1", citing: "G1"), clause("c2", citing: "auth/login#ac-1"), clause("c3", citing: "billing/pay")
        ]))

        let title = try world.card("BACK-1").title ?? "BACK-1"
        let worker = try #require(dispatch.requests.passes(.worker).first?.instruction.cardInstruction)
        #expect(worker.commitMessage == CommitMessageRequest(
            message: "fix(auth): \(title) [YLH-7] auth/login backend", cardKey: "YLH-7"
        ))
        let text = worker.render()
        #expect(text.contains("    fix(auth): \(title) [YLH-7] auth/login backend\n"))
        #expect(text.contains("Yellowhammer-Card: YLH-7"))

        for pass in [RunPass.architect, .reviewer] {
            let other = try #require(dispatch.requests.passes(pass).first?.instruction.cardInstruction)
            #expect(other.commitMessage == nil)
            #expect(!other.render().contains("## Commit messages"))
        }
    }

    @Test("A Card citing only a goal ID renders an empty scope and story")
    func goalOnlyCitationRendersEmptyScopeAndStory() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        try await scriptBoard(world)
        let dispatch = LoggingDispatch(log: CallLog())
        let cardRun = makeRun(
            dispatch: dispatch, commitMessage: try MessageTemplate(template, kind: .commitMessage),
            changeType: try #require(ChangeType("fix"))
        )

        try await run(cardRun, in: world, readiness: readiness([clause("c1", citing: "G1")]))

        let title = try world.card("BACK-1").title ?? "BACK-1"
        let worker = try #require(dispatch.requests.passes(.worker).first?.instruction.cardInstruction)
        #expect(worker.commitMessage?.message == "fix: \(title) [YLH-7]  backend")
    }

    @Test("With no board object the key is empty and no trailer sentence is rendered")
    func noBoardObjectRendersNoTrailer() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let dispatch = LoggingDispatch(log: CallLog())

        try await run(makeRun(dispatch: dispatch), in: world, readiness: readiness([]))

        let worker = try #require(dispatch.requests.passes(.worker).first?.instruction.cardInstruction)
        #expect(worker.commitMessage?.cardKey == nil)
        #expect(!worker.render().contains("Yellowhammer-Card"))
        #expect(worker.render().contains("## Commit messages"))
    }

    @Test("WorkerCommitMessage fills every token; story picks the first story in clause order")
    func rendererUnit() throws {
        let inputs = WorkerCommitMessage.Inputs(
            cardKey: "YLH-7", cardTitle: "Fix", featureKey: "YLH-1", featureTitle: "Login",
            repository: "backend", story: "auth/login"
        )
        let all = try MessageTemplate(
            "{type}{scope}|{title}|{key}|{repository}|{card_key}|{card_title}|{story}", kind: .commitMessage
        )
        #expect(
            WorkerCommitMessage.render(template: all, changeType: .feat, inputs: inputs)
                == "feat(auth)|Login|YLH-1|backend|YLH-7|Fix|auth/login"
        )
        var none = inputs
        none.story = nil
        #expect(WorkerCommitMessage.render(template: all, changeType: .feat, inputs: none)
            == "feat|Login|YLH-1|backend|YLH-7|Fix|")

        let clauses = [clause("c1", citing: "G1"), clause("c2", citing: "b/two"), clause("c3", citing: "a/one")]
        #expect(WorkerCommitMessage.story(clauses: clauses, description: nil) == "b/two")
        let description = "<!-- yh:clause:c3 --> x <!-- yh:clause:c2 --> y"
        #expect(WorkerCommitMessage.story(clauses: clauses, description: description) == "a/one")
        #expect(WorkerCommitMessage.story(clauses: [clause("c1", citing: "G1")], description: nil) == nil)
    }

    // MARK: - The trailer record

    private func missingTrailerCommits(_ journal: JournalStore) throws -> [String] {
        try journal.events(ofType: .cardCommitTrailerMissing).compactMap {
            guard case .cardCommitTrailerMissing(_, _, _, let commit) = $0.event else { return nil }
            return commit
        }
    }

    @Test("A reported commit with no trailer is recorded; the Card ends Done exactly as without the record")
    func missingTrailerIsRecordedAndOutcomeUnchanged() async throws {
        let repo = GateGitFixture(name: "cardrun-trailer-\(UUID().uuidString)")
        await repo.initRepo()
        let base = try await repo.commit(filename: "a.txt", message: "initial")
        _ = try await repo.commit(filename: "b.txt", message: "feat: tagged\n\nYellowhammer-Card: YLH-7")
        let bare = try await repo.commit(filename: "c.txt", message: "feat: bare")

        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open(), worktreePath: { _ in repo.path })
        try await recordKnownGood(base, world: world)

        try await run(makeRun(dispatch: LoggingDispatch(log: CallLog())), in: world, readiness: readiness([]))

        #expect(try missingTrailerCommits(world.journal) == [bare])
        #expect(try cardRunLog(world.journal) == [
            "lease-claimed", "attempt-started", "→ In Progress", "architect", "worker", "check", "reviewer",
            "attempt ended: success", "→ Done", "lease-released"
        ])
        #expect(try world.card("BACK-1").state == .done)
        #expect(try world.attempts("BACK-1").flatMap(\.rounds).isEmpty)
    }

    @Test("A Round that re-reports the same HEAD does not record the commit twice")
    func roundDoesNotRecordTwice() async throws {
        let repo = GateGitFixture(name: "cardrun-trailer-round-\(UUID().uuidString)")
        await repo.initRepo()
        let base = try await repo.commit(filename: "a.txt", message: "initial")
        let bare = try await repo.commit(filename: "c.txt", message: "feat: bare")

        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open(), worktreePath: { _ in repo.path })
        try await recordKnownGood(base, world: world)
        let dispatch = ChangesOnceDispatch()

        try await run(makeRun(dispatch: dispatch), in: world, readiness: readiness([]))

        #expect(dispatch.workerCalls.withLock { $0 } == 2)
        #expect(try missingTrailerCommits(world.journal) == [bare])
        #expect(try world.card("BACK-1").state == .done)
    }

    @Test("A reported commit git cannot read is recorded as unread, and the Card's outcome is unchanged")
    func unreadableCommitIsRecordedAsUnread() async throws {
        let repo = GateGitFixture(name: "cardrun-trailer-unread-\(UUID().uuidString)")
        await repo.initRepo()
        let base = try await repo.commit(filename: "a.txt", message: "initial")
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open(), worktreePath: { _ in repo.path })
        try await recordKnownGood(base, world: world)
        let unknown = String(repeating: "0", count: 40)
        let dispatch = StaticWorkerCommitDispatch(commit: unknown)

        try await run(makeRun(dispatch: dispatch), in: world, readiness: readiness([]))

        let unread = try world.journal.events(ofType: .cardCommitTrailersUnread).compactMap { record -> String? in
            guard case .cardCommitTrailersUnread(_, _, _, let commit, let reason) = record.event,
                !reason.isEmpty else { return nil }
            return commit
        }
        #expect(unread == [unknown])
        #expect(try missingTrailerCommits(world.journal).isEmpty)
        #expect(try world.card("BACK-1").state == .done)
        #expect(try world.attempts("BACK-1").flatMap(\.rounds).isEmpty)
    }

    private func recordKnownGood(_ commit: String, world: CardRunWorld) async throws {
        let worktree = try #require(
            try world.journal.heldWorktree(featureID: world.context.feature.id, repository: "backend")
        )
        _ = try world.journal.recordWorktreeKnownGood(id: worktree.id, commit: commit, runID: world.runID)
    }
}

/// A Dispatch seam answering like ``RehearsalDispatch``, except the worker reports `commit` instead of
/// the Worktree's HEAD, so a test can report a sha the Worktree does not have.
private struct StaticWorkerCommitDispatch: AgentDispatch {
    let commit: String

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        let report = try await RehearsalDispatch().dispatch(request)
        guard request.pass == .worker, case .completed(.worker(let result)) = report.outcome,
            case .completed(_, let summary) = result.outcome
        else { return report }
        return AgentDispatchReport(
            outcome: .completed(.worker(WorkerResult(outcome: .completed(commit: commit, summary: summary)))),
            session: report.session
        )
    }
}

/// A Dispatch seam answering like ``RehearsalDispatch`` (so the worker reports the Worktree's real HEAD),
/// except the first review asks for changes: the worker goes again and re-reports the same HEAD.
private final class ChangesOnceDispatch: AgentDispatch, Sendable {
    let workerCalls = Mutex(0)
    private let reviewerCalls = Mutex(0)

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        if request.pass == .worker { workerCalls.withLock { $0 += 1 } }
        let first = request.pass == .reviewer && reviewerCalls.withLock { calls in
            calls += 1
            return calls == 1
        }
        let script: RehearsalScript = first ? [.reviewer: .reviewerChangesRequested] : [:]
        return try await RehearsalDispatch(script: script).dispatch(request)
    }
}
