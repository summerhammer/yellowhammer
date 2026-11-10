import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import GRDB
@testable import Journal
import Repositories
import Synchronization
import Testing

// Fixtures for FeatureSettleGestureTests.swift (roadmap P10.9, P22.2): a Feature → Cycle → four-Card
// world, with a Worktree Port so Done and Cancelled can be exercised without real git fixtures — the
// native-disposition seam never reads git or GitHub.

let settlePreviousNightStart = NightStart(rawValue: "2026-09-10")!
let settleObservingNightStart = NightStart(rawValue: "2026-09-12")!
let settleFeatureBranch = "yh-proj-settle"

/// Records every Workspace call; creates no real directories. The settle gesture's *released* value is
/// the one caller that must be able to discard an unpushed Worktree, so `removeCalls` is what a test
/// reads to see that happened.
final class FakeSettleWorkspace: Workspace, Sendable {
    func registeredRepositoryPaths() async throws(WorkspaceError) -> [String] { [] }
    func registerRepository(path: String) async throws(WorkspaceError) -> RegistrationID { RegistrationID(rawValue: path) }
    struct RemoveCall: Equatable, Sendable {
        let id: WorktreeID
        let force: Bool
    }

    private let state = Mutex<[RemoveCall]>([])

    var removeCalls: [RemoveCall] { state.withLock { $0 } }

    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        WorkspaceWorktree(id: WorktreeID(rawValue: "wt-\(name)"), path: "/tmp/\(name)", branch: name, displayName: name)
    }

    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] { [] }

    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) {
        state.withLock { $0.append(RemoveCall(id: id, force: force)) }
    }

    func createTerminal(
        worktreeID: WorktreeID, title: String, command: String
    ) async throws(WorkspaceError) -> WorkspaceTerminal {
        WorkspaceTerminal(handle: TerminalHandle(rawValue: "term-\(worktreeID.rawValue)"), processID: nil)
    }

    func terminal(_ handle: TerminalHandle) async throws(WorkspaceError) -> WorkspaceTerminalState {
        WorkspaceTerminalState(orphaned: false, processID: nil)
    }

    func closeTerminal(_ handle: TerminalHandle) async throws(WorkspaceError) {}
}

/// A Feature → Cycle → four Cards world (Done, Waiting on You, Blocked, Shelved), with a real board
/// and Workspace Port wired — for ``FeatureSettleGesture``'s own seam tests.
final class SettleWorld {
    let fixture: OutboxJournalFixture
    let journal: JournalStore
    let boards: NightCardTestBoards
    let reading: FakeReadingBoard
    let workspace: FakeSettleWorkspace
    let featureID: Int64
    let cycleID: Int64
    let previousNightID: Int64
    let doneCardID: Int64
    let waitingCardID: Int64
    let blockedCardID: Int64
    let shelvedCardID: Int64

    init(
        fixture: consuming OutboxJournalFixture, journal: JournalStore, boards: NightCardTestBoards,
        reading: FakeReadingBoard, workspace: FakeSettleWorkspace, featureID: Int64, cycleID: Int64,
        previousNightID: Int64, doneCardID: Int64, waitingCardID: Int64, blockedCardID: Int64, shelvedCardID: Int64
    ) {
        self.fixture = fixture
        self.journal = journal
        self.boards = boards
        self.reading = reading
        self.workspace = workspace
        self.featureID = featureID
        self.cycleID = cycleID
        self.previousNightID = previousNightID
        self.doneCardID = doneCardID
        self.waitingCardID = waitingCardID
        self.blockedCardID = blockedCardID
        self.shelvedCardID = shelvedCardID
    }

    /// Builds a fresh `ActContext` for an author Act firing on `nightStart`: claims the Act Lease,
    /// opens the Night, and wires a fresh Outbox, board and Workspace to it.
    func makeContext(
        nightStart: NightStart = settleObservingNightStart, repositories: ProjectRepositories? = nil,
        mode: NightMode = .real
    ) throws -> ActContext {
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: mode) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        let opening = try journal.openNight(nightStart: nightStart, mode: mode, act: .author, runID: runID)
        let outbox = Outbox(
            journal: journal, board: boards.writing, runID: runID, act: .author, nightID: opening.night.id
        )
        let board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)
        return ActContext(
            act: .author, mode: mode, trigger: .scheduled, runID: runID, journal: journal, night: opening.night,
            outbox: outbox, board: board, workspace: workspace, repositories: repositories ?? landThrowawayRepositories
        )
    }

    /// Seeds the Feature Issue's read workflow state for the native-disposition seam: a state `name` of
    /// the given native `category`, with an id of its own (so it never collides with a provisioned state).
    func seedFeatureIssueState(_ name: String, category: BoardWorkflowStateCategory? = nil) async {
        await seedFeatureIssue(
            state: BoardWorkflowState(id: BoardObjectID(rawValue: "state-\(name)"), name: name, category: category)
        )
    }

    func seedFeatureIssue(state: BoardWorkflowState) async {
        await reading.seed(
            issue: BoardObject(
                id: BoardObjectID(rawValue: "FEAT-1"), key: "FEAT-1", title: "Feature", description: nil,
                workflowState: state, labels: [], parent: nil, url: "https://example.com/FEAT-1",
                createdAt: outboxEpoch, updatedAt: outboxEpoch
            )
        )
    }

    /// The Feature Card in the board's own Done state (native `completed`), as the Operator moves it.
    func seedFeatureDone() async throws {
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        await seedFeatureIssue(
            state: BoardWorkflowState(id: try scope.id(for: .done), name: "Done", category: .completed)
        )
    }

    /// The Feature Card in a Cancelled state (Linear `canceled`, which the adapter reads as `shelved`).
    func seedFeatureCancelled() async {
        await seedFeatureIssueState("Cancelled", category: .shelved)
    }

    /// Adds unfinished Cards to a still-running Feature; release must carry both forward.
    func seedActiveCards() async throws -> (todo: Int64, inProgress: Int64) {
        for issueID in ["BACK-3", "MOB-3"] {
            await boards.writing.seed(issue: issueID, description: nil)
            _ = try await boards.writing.updateIssue(
                BoardObjectID(rawValue: issueID),
                BoardIssueChange(parent: .set(BoardObjectID(rawValue: "FEAT-1")))
            )
        }
        let todo = try insertMergeCard(
            journal, cycleID: cycleID, issueID: "BACK-3", repository: "backend", state: .todo, budgetEpoch: 3
        )
        let inProgress = try insertMergeCard(
            journal, cycleID: cycleID, issueID: "MOB-3", repository: "mobile", state: .inProgress,
            budgetEpoch: 4
        )
        try journal.write { db in
            try db.execute(
                sql: """
                INSERT INTO attempt (card_id, budget_epoch, route_cli, route_model, route_effort, started_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [inProgress, 4, "claude", "sonnet", "medium", JournalStore.timestamp(outboxEpoch)]
            )
            try db.execute(
                sql: "INSERT INTO round (attempt_id, lens, verdict, created_at) VALUES (?, ?, ?, ?)",
                arguments: [db.lastInsertedRowID, "check", "failed", JournalStore.timestamp(outboxEpoch)]
            )
        }
        return (todo, inProgress)
    }

    /// Holds a Worktree for the Feature's `repository`, pushed or not.
    @discardableResult
    func holdWorktree(repository: String, pushed: Bool) throws -> WorktreeRecord {
        try holdWorktree(
            repository: repository, path: "/tmp/\(repository)", pushedCommit: pushed ? "abc123" : nil
        )
    }

    /// Holds a Worktree for the Feature's `repository` at `path`, optionally with `pushedCommit`.
    @discardableResult
    func holdWorktree(repository: String, path: String, pushedCommit: String? = nil) throws -> WorktreeRecord {
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .real) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        var record = try journal.recordWorktree(
            featureID: featureID, repository: repository, worktreeID: "wt-\(repository)", path: path,
            runID: runID
        )
        if let pushedCommit {
            record = try journal.recordWorktreePush(id: record.id, commit: pushedCommit, runID: runID)
        }
        try journal.releaseActLease(runID: runID)
        return record
    }
}

/// Builds a `SettleWorld`. `inFlight` and `landed` shape the Cycle exactly as
/// ``JournalStore/inFlightLandedFeature()`` reads it: `landed: true` with `inFlight: true` is a Partial
/// Landing, the one shape the settle gesture's offered set narrows for.
func makeSettleWorld(
    inFlight: Bool = true, landed: Bool = false, allShelved: Bool = false
) async throws -> SettleWorld {
    let fixture = try OutboxJournalFixture()
    let journal = try fixture.open()
    let boards = try await makeBuildActBoards()
    for issueID in ["FEAT-1", "BACK-1", "MOB-1", "BACK-2", "MOB-2"] {
        await boards.writing.seed(issue: issueID, description: nil)
    }
    for card in ["BACK-1", "MOB-1", "BACK-2", "MOB-2"] {
        _ = try await boards.writing.updateIssue(
            BoardObjectID(rawValue: card), BoardIssueChange(parent: .set(BoardObjectID(rawValue: "FEAT-1")))
        )
    }

    let featureID = try insertGateFeature(
        journal, issueID: "FEAT-1", branch: settleFeatureBranch, repositories: ["backend", "mobile"],
        inFlight: inFlight, landed: landed
    )
    let cycleID = try gateCycleID(journal, featureID: featureID)
    let cards = try insertSettleCards(journal, cycleID: cycleID, allShelved: allShelved)
    let previousNightID = try openAndCloseSettleNight(journal, nightStart: settlePreviousNightStart)

    return SettleWorld(
        fixture: fixture, journal: journal, boards: boards, reading: FakeReadingBoard.quiet(2),
        workspace: FakeSettleWorkspace(), featureID: featureID, cycleID: cycleID, previousNightID: previousNightID,
        doneCardID: cards.doneCardID, waitingCardID: cards.waitingCardID, blockedCardID: cards.blockedCardID,
        shelvedCardID: cards.shelvedCardID
    )
}

/// The four Cards ``makeSettleWorld(inFlight:landed:allShelved:)`` inserts, split out to keep that
/// function under the function-body-length limit.
private struct SettleCardIDs {
    let doneCardID: Int64
    let waitingCardID: Int64
    let blockedCardID: Int64
    let shelvedCardID: Int64
}

private func insertSettleCards(_ journal: JournalStore, cycleID: Int64, allShelved: Bool) throws -> SettleCardIDs {
    guard !allShelved else {
        return SettleCardIDs(
            doneCardID: try insertMergeCard(
                journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .shelved
            ),
            waitingCardID: try insertMergeCard(
                journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile", state: .shelved
            ),
            blockedCardID: try insertMergeCard(
                journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend", state: .shelved
            ),
            shelvedCardID: try insertMergeCard(
                journal, cycleID: cycleID, issueID: "MOB-2", repository: "mobile", state: .shelved
            )
        )
    }
    return SettleCardIDs(
        doneCardID: try insertMergeCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .done
        ),
        waitingCardID: try insertMergeCard(
            journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile", state: .waitingOnYou, budgetEpoch: 2
        ),
        blockedCardID: try insertMergeCard(
            journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend", state: .blocked,
            blockReason: .reviewerRejection
        ),
        shelvedCardID: try insertMergeCard(
            journal, cycleID: cycleID, issueID: "MOB-2", repository: "mobile", state: .shelved
        )
    )
}

func settleNightTriagedAt(_ journal: JournalStore, nightID: Int64) throws -> Date? {
    try journal.night(id: nightID)?.triagedAt
}

private func openAndCloseSettleNight(_ journal: JournalStore, nightStart: NightStart) throws -> Int64 {
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .real) else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: runID)
    try journal.closeNight(id: opening.night.id, reason: .nightEnd, act: .author, runID: runID)
    try journal.releaseActLease(runID: runID)
    return opening.night.id
}

// Real-git fixtures shared by the cancellation pin (OQ194) and snapshot (OQ196) suites: a main clone with a bare
// `origin` and a `git worktree add` Worktree on the Feature Branch.

struct TestWorktreeEnvironment {
    let clone: TestGitRepo
    let remote: TestGitRepo
    let worktreePath: String
    let base: String
}

func makeGitWorktree(
    name: String = "backend", branch: String = settleFeatureBranch
) async throws -> TestWorktreeEnvironment {
    let clone = TestGitRepo(name: "oq194-\(name)-clone")
    await clone.initRepo(defaultBranch: "main")
    let base = try await clone.commit(filename: "README.md", content: name, message: "initial")
    let remote = TestGitRepo(name: "oq194-\(name)-remote")
    await remote.initRepo(bare: true, defaultBranch: "main")
    await clone.addRemote(url: remote.path)
    #expect(await clone.run(["push", "origin", "main"]).isSuccess)
    let worktreeURL = clone.url.appending(component: "wt-\(name)", directoryHint: .isDirectory)
    let worktreePath = worktreeURL.path(percentEncoded: false)
    #expect(await clone.run(["worktree", "add", "-b", branch, worktreePath]).isSuccess)
    return TestWorktreeEnvironment(clone: clone, remote: remote, worktreePath: worktreePath, base: base)
}

func commitInWorktree(
    _ worktreePath: String, filename: String = "work.txt", content: String = "content", message: String = "commit"
) async throws -> String {
    let fileURL = URL(fileURLWithPath: worktreePath).appendingPathComponent(filename)
    try content.write(to: fileURL, atomically: true, encoding: .utf8)
    let git = GitRunner()
    _ = await git.run(["-C", worktreePath, "add", "."])
    _ = await git.run(["-C", worktreePath, "commit", "-m", message])
    let res = await git.run(["-C", worktreePath, "rev-parse", "--verify", "HEAD"])
    return res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

func inFlightFeature(_ world: SettleWorld) throws -> FeatureRecord {
    try #require(try world.journal.inFlightFeature()?.feature)
}

/// Records `commit` as the Pushed Tip of the world's Cycle in `repository`, under an Act lease.
func recordPushedTip(_ world: SettleWorld, repository: String, commit: String) throws {
    let runID = RunID()
    guard case .claimed = try world.journal.claimActLease(act: .land, runID: runID, mode: .real) else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    try world.journal.recordPushedTip(
        cycleID: world.cycleID, repository: repository, commit: commit, runID: runID
    )
    try world.journal.releaseActLease(runID: runID)
}
