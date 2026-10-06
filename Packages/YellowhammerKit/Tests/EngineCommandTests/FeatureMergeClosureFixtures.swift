import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import GRDB
@testable import Journal
import Repositories
import Testing

// Fixtures for FeatureMergeClosureTests.swift (roadmap P10.8): a Feature → Cycle → four-Card world over
// two real fixture git repositories, with the Cycle landed on an earlier Night than the observing one.

let mergeClosureLandingNightStart = NightStart(rawValue: "2026-09-10")!
let mergeClosureObservingNightStart = NightStart(rawValue: "2026-09-12")!
let mergeClosureBranch = "yh-proj-merge-closure"

/// Inserts a fixture Card with an explicit state (and Block Reason, for a Blocked Card), mirroring
/// `insertGateCard` but letting the world seed every state the closure must tell apart.
@discardableResult
func insertMergeCard(
    _ journal: JournalStore, cycleID: Int64, issueID: String, repository: String, state: CardState,
    blockReason: BlockReason? = nil, budgetEpoch: Int = 0
) throws -> Int64 {
    try journal.write { db in
        let nextOrder = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(authored_order), 0) + 1 FROM card WHERE cycle_id = ? AND repository = ?",
            arguments: [cycleID, repository]
        ) ?? 1
        try db.execute(
            sql: """
            INSERT INTO card (
                cycle_id, issue_id, repository, kind, authored_order, state, block_reason, budget_epoch,
                created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, repository, "card", nextOrder, state.rawValue, blockReason?.rawValue,
                budgetEpoch, JournalStore.timestamp(outboxEpoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

/// A Feature → Cycle → four Cards world (Done, Waiting on You, Blocked, Cancelled), with two touched
/// repositories (`backend`, `mobile`) backed by real fixture git repositories, and a real board wired —
/// for ``FeatureMergeClosure``'s own seam tests and the gate's end-to-end integration.
final class MergeWorld {
    let fixture: OutboxJournalFixture
    let journal: JournalStore
    let boards: NightCardTestBoards
    let backend: GateGitFixture
    let mobile: GateGitFixture
    let featureID: Int64
    let cycleID: Int64
    let landingNightID: Int64
    var observingNightID: Int64
    let doneCardID: Int64
    let waitingCardID: Int64
    let blockedCardID: Int64
    let cancelledCardID: Int64

    init(
        fixture: consuming OutboxJournalFixture, journal: JournalStore, boards: NightCardTestBoards,
        backend: consuming GateGitFixture, mobile: consuming GateGitFixture, featureID: Int64, cycleID: Int64,
        landingNightID: Int64, observingNightID: Int64, doneCardID: Int64, waitingCardID: Int64,
        blockedCardID: Int64, cancelledCardID: Int64
    ) {
        self.fixture = fixture
        self.journal = journal
        self.boards = boards
        self.backend = backend
        self.mobile = mobile
        self.featureID = featureID
        self.cycleID = cycleID
        self.landingNightID = landingNightID
        self.observingNightID = observingNightID
        self.doneCardID = doneCardID
        self.waitingCardID = waitingCardID
        self.blockedCardID = blockedCardID
        self.cancelledCardID = cancelledCardID
    }

    /// Builds a fresh `ActContext` for a new author Act firing on the observing Night: claims the Act
    /// Lease, re-opens the (already-recorded) observing Night, and wires a fresh Outbox to it — the same
    /// shape a second gate pass or a retried closure call would see.
    func makeContext(repositories: ProjectRepositories) throws -> ActContext {
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .real) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        let opening = try journal.openNight(
            nightStart: mergeClosureObservingNightStart, mode: .real, act: .author, runID: runID
        )
        let outbox = Outbox(
            journal: journal, board: boards.writing, runID: runID, act: .author, nightID: opening.night.id
        )
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        return ActContext(
            act: .author, mode: .real, trigger: .scheduled, runID: runID, journal: journal, night: opening.night,
            outbox: outbox, board: board, repositories: repositories
        )
    }
}

/// Builds a `MergeWorld`, merging `mergedRepositories` into their fixture mainlines before the Feature
/// is ever tested — `k` is however many of `["backend", "mobile"]` are in that set. The Cycle lands on
/// an earlier Night than the one the world's context observes ancestry on, so the triaged-Night rule
/// has two distinct Nights to tell apart, unless `landInObservingNight` says otherwise.
func makeMergeWorld(
    mergedRepositories: Set<String>, landInObservingNight: Bool = false
) async throws -> MergeWorld {
    let backend = try await makeMergeRepository("backend", merged: mergedRepositories.contains("backend"))
    let mobile = try await makeMergeRepository("mobile", merged: mergedRepositories.contains("mobile"))

    let fixture = try OutboxJournalFixture()
    let journal = try fixture.open()
    let boards = try await makeBuildActBoards()
    await boards.writing.seed(issue: "FEAT-1", description: nil)
    await boards.writing.seed(issue: "BACK-1", description: nil)
    await boards.writing.seed(issue: "MOB-1", description: nil)
    await boards.writing.seed(issue: "BACK-2", description: nil)
    await boards.writing.seed(issue: "MOB-2", description: nil)
    // Every Card starts as a sub-issue of the Feature Issue, so a detachment is observable on the board.
    for card in ["BACK-1", "MOB-1", "BACK-2", "MOB-2"] {
        _ = try await boards.writing.updateIssue(
            BoardObjectID(rawValue: card), BoardIssueChange(parent: .set(BoardObjectID(rawValue: "FEAT-1")))
        )
    }

    let featureID = try insertGateFeature(
        journal, issueID: "FEAT-1", branch: mergeClosureBranch, repositories: ["backend", "mobile"],
        inFlight: true, landed: false
    )
    let cycleID = try gateCycleID(journal, featureID: featureID)
    let doneCardID = try insertMergeCard(
        journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .done
    )
    let waitingCardID = try insertMergeCard(
        journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile", state: .waitingOnYou, budgetEpoch: 2
    )
    let blockedCardID = try insertMergeCard(
        journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend", state: .blocked,
        blockReason: .reviewerRejection
    )
    let cancelledCardID = try insertMergeCard(
        journal, cycleID: cycleID, issueID: "MOB-2", repository: "mobile", state: .cancelled
    )

    let landingNightID = try landMergeCycle(journal, cycleID: cycleID, inObservingNight: landInObservingNight)

    return MergeWorld(
        fixture: fixture, journal: journal, boards: boards, backend: backend, mobile: mobile, featureID: featureID,
        cycleID: cycleID, landingNightID: landingNightID,
        observingNightID: landInObservingNight ? landingNightID : -1, doneCardID: doneCardID,
        waitingCardID: waitingCardID, blockedCardID: blockedCardID, cancelledCardID: cancelledCardID
    )
}

func mergeWorldRepositories(_ world: MergeWorld) -> ProjectRepositories {
    ProjectRepositories(workingRepos: [
        Repo(name: "backend", path: world.backend.path, role: .backend),
        Repo(name: "mobile", path: world.mobile.path, role: .mobile)
    ])
}

func mergeFeatureRow(_ journal: JournalStore, featureID: Int64) throws -> (state: String, closedBy: String?) {
    try journal.read { db in
        let row = try Row.fetchOne(
            db, sql: "SELECT state, closed_by FROM feature WHERE id = ?", arguments: [featureID]
        )!
        return (row["state"], row["closed_by"])
    }
}

func mergeNightTriagedAt(_ journal: JournalStore, nightID: Int64) throws -> Date? {
    try journal.night(id: nightID)?.triagedAt
}

/// One fixture repository with the Feature Branch cut from `main` and, when `merged`, merged back into it.
private func makeMergeRepository(_ name: String, merged: Bool) async throws -> GateGitFixture {
    let repository = GateGitFixture(name: "merge-closure-\(name)-\(UUID().uuidString)")
    await repository.initRepo()
    _ = try await repository.commit(message: "init")
    _ = await repository.run(["checkout", "-b", mergeClosureBranch])
    _ = try await repository.commit(filename: "feat.txt", content: "feat", message: "feature commit")
    _ = await repository.run(["checkout", "main"])
    if merged {
        _ = await repository.run(["merge", "--no-ff", "-m", "merge", mergeClosureBranch])
    }
    return repository
}

/// Lands the Cycle on its own Night — before the observing Night the world hands out contexts for, unless
/// `inObservingNight` — recording the `cycleLanded` event the triaged-Night rule reads. Returns that Night.
private func landMergeCycle(_ journal: JournalStore, cycleID: Int64, inObservingNight: Bool) throws -> Int64 {
    let landRunID = RunID()
    guard case .claimed = try journal.claimActLease(act: .land, runID: landRunID, mode: .real) else {
        throw JournalError.actLeaseLost(runID: landRunID, holder: nil)
    }
    let nightStart = inObservingNight ? mergeClosureObservingNightStart : mergeClosureLandingNightStart
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .land, runID: landRunID)
    try journal.markCycleLanded(cycleID: cycleID, runID: landRunID)
    try journal.append(.cycleLanded(cycleID: cycleID), act: .land, runID: landRunID, nightID: opening.night.id)
    if !inObservingNight {
        try journal.closeNight(id: opening.night.id, reason: .nightEnd, act: .land, runID: landRunID)
    }
    try journal.releaseActLease(runID: landRunID)
    return opening.night.id
}
