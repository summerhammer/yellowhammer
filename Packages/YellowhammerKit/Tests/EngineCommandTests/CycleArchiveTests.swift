import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import GRDB
import Repositories
import Testing

// roadmap P10.7 (spec: verification/archive-the-cycle-on-a-verified-feature): a Feature with every
// Definition of Done clause met has its Cycle archived: the Feature Issue moves to Done, closed_by is
// recorded `verification`, and any surviving Blocked Card is detached from the Feature Issue (parentId
// cleared) with its counters, round history and Block Reason left for later adoption. Archival never
// merges or closes a pull request, and does not by itself release the next Feature — the
// predecessor-ancestry gate still requires ancestry. Never asserts model-authored content.

private let archiveEpoch = Date(timeIntervalSince1970: 1_800_000_000)
private let archiveNightStart = NightStart(rawValue: "2026-09-16")!
private let archiveBranch = FeatureBranch(rawValue: "yh-proj-feat")

private func archiveClause(
    _ cid: String, issue: String = "BACK-1", verdict: ClauseVerdict
) -> ClauseVerificationRecord {
    ClauseVerificationRecord(
        issueID: issue, cid: cid, level: "card", text: "Clause \(cid).", locationID: "epic/story",
        citationProvenance: "machine-found", verdict: verdict, whatWasChecked: "checked \(cid)",
        interpretation: "read \(cid)", judgedBy: verdict == .met ? .agent : .engine
    )
}

/// A Feature → Cycle → two Cards world (one Done, one Blocked), with a real board wired, for
/// ``CycleArchive``'s own seam tests.
private final class ArchiveWorld {
    let fixture: OutboxJournalFixture
    let journal: JournalStore
    let boards: NightCardTestBoards
    let context: ActContext
    let featureID: Int64
    let cycleID: Int64
    let feature: FeatureRecord
    let runID: RunID
    let doneCardID: Int64
    let blockedCardID: Int64

    init(
        fixture: consuming OutboxJournalFixture, journal: JournalStore, boards: NightCardTestBoards,
        context: ActContext, featureID: Int64, cycleID: Int64, feature: FeatureRecord, runID: RunID,
        doneCardID: Int64, blockedCardID: Int64
    ) {
        self.fixture = fixture
        self.journal = journal
        self.boards = boards
        self.context = context
        self.featureID = featureID
        self.cycleID = cycleID
        self.feature = feature
        self.runID = runID
        self.doneCardID = doneCardID
        self.blockedCardID = blockedCardID
    }

    var featureContext: LandActFeatureContext {
        LandActFeatureContext(act: context, feature: feature, cycleID: cycleID)
    }
}

private func makeArchiveWorld() async throws -> ArchiveWorld {
    let fixture = try OutboxJournalFixture()
    let journal = try fixture.open()
    let boards = try await makeBuildActBoards()
    await boards.writing.seed(issue: "FEAT-1", description: nil)
    await boards.writing.seed(issue: "MOB-1", description: nil)
    let runID = RunID()
    try claimLandLease(journal, runID: runID)
    let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
    try journal.recordFeatureBranch(featureID: featureID, branch: archiveBranch)
    let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
    let doneCardID = try insertReconcilerCard(
        journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .done
    )
    let blockedCardID = try insertReconcilerCard(
        journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile", state: .blocked
    )

    let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
    let night = try journal.openNight(nightStart: archiveNightStart, mode: .real, act: .land, runID: runID).night
    let outbox = Outbox(
        journal: journal, board: boards.writing, runID: runID, act: .land, nightID: night.id, clock: { archiveEpoch }
    )
    let context = ActContext(
        act: .land, mode: .real, trigger: .scheduled, runID: runID, journal: journal, night: night,
        outbox: outbox, board: board, mainlines: selectionMainlines(), repositories: selectionRepositories()
    )
    let (feature, _) = try #require(try journal.inFlightFeature())
    return ArchiveWorld(
        fixture: fixture, journal: journal, boards: boards, context: context, featureID: featureID, cycleID: cycleID,
        feature: feature, runID: runID, doneCardID: doneCardID, blockedCardID: blockedCardID
    )
}

private func recordVerification(_ world: ArchiveWorld, clauses: [ClauseVerificationRecord]) throws {
    try world.journal.recordFeatureVerification(NewFeatureVerification(
        featureID: world.featureID, cycleID: world.cycleID, route: nil, nightID: world.context.night.id,
        runID: world.runID, clauses: clauses
    ))
}

private func featureRow(_ journal: JournalStore, featureID: Int64) throws -> (state: String, closedBy: String?) {
    try journal.read { db in
        let row = try Row.fetchOne(
            db, sql: "SELECT state, closed_by FROM feature WHERE id = ?", arguments: [featureID]
        )!
        return (row["state"], row["closed_by"])
    }
}

@Suite("Archive the Cycle on a verified Feature (P10.7)")
struct CycleArchiveTests {
    @Test("An all-met verdict archives the Cycle: closed_by verification, Feature Issue Done, Blocked Card detached")
    func archivesOnAllMet() async throws {
        let world = try await makeArchiveWorld()
        try recordVerification(world, clauses: [archiveClause("c1", verdict: .met)])

        try await CycleArchive().archive(world.featureContext)

        let row = try featureRow(world.journal, featureID: world.featureID)
        #expect(row.state == "closed")
        #expect(row.closedBy == "verification")
        #expect(try world.journal.inFlightCycleID() == nil)

        let events = try world.journal.events(ofType: .cycleArchived)
        #expect(events.map(\.event) == [
            .cycleArchived(cycleID: world.cycleID, featureIssueID: "FEAT-1", closedBy: .verification, detachedCards: 1)
        ])

        let featureIssue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "FEAT-1")))
        let scope = try await BoardStateScope.resolve(using: world.boards.provisioning)
        #expect(featureIssue.workflowState == (try scope.id(for: .done)))

        let blockedIssue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "MOB-1")))
        #expect(blockedIssue.parent == nil)

        // The Blocked Card's Journal row is untouched: still Blocked, its counters intact.
        let cards = try world.journal.cards(cycleID: world.cycleID)
        let blockedCard = try #require(cards.first { $0.id == world.blockedCardID })
        #expect(blockedCard.state == .blocked)
        let doneCard = try #require(cards.first { $0.id == world.doneCardID })
        #expect(doneCard.state == .done)

        // Exactly two board writes: the Blocked Card's detach and the Feature Issue's Done — no pull
        // request or comment write of any kind.
        #expect(await world.boards.writing.updateCalls == 2)
        #expect(await world.boards.writing.createCommentCalls == 0)
    }

    @Test("A retry (the same land Act firing again) appends no second event and posts no duplicate writes")
    func retryIsIdempotent() async throws {
        let world = try await makeArchiveWorld()
        try recordVerification(world, clauses: [archiveClause("c1", verdict: .met)])

        try await CycleArchive().archive(world.featureContext)
        try await CycleArchive().archive(world.featureContext)

        #expect(try world.journal.events(ofType: .cycleArchived).count == 1)
        #expect(await world.boards.writing.updateCalls == 2)
    }

    @Test("An unmet clause faults: nothing is archived, the Feature Issue is untouched")
    func faultsOnUnmetVerdict() async throws {
        let world = try await makeArchiveWorld()
        try recordVerification(world, clauses: [archiveClause("c1", verdict: .unmet)])

        await #expect(throws: CycleArchiveFault.self) {
            try await CycleArchive().archive(world.featureContext)
        }

        #expect(try world.journal.inFlightCycleID() == world.cycleID)
        #expect(await world.boards.writing.updateCalls == 0)
    }

    @Test("An unresolved clause faults: defence in depth against the verdict's own all-met rule")
    func faultsOnUnresolvedVerdict() async throws {
        let world = try await makeArchiveWorld()
        try recordVerification(world, clauses: [archiveClause("c1", verdict: .unresolved)])

        await #expect(throws: CycleArchiveFault.self) {
            try await CycleArchive().archive(world.featureContext)
        }

        #expect(try world.journal.inFlightCycleID() == world.cycleID)
    }

    @Test("With no recorded Verification, archiving faults")
    func faultsWithoutARecordedVerification() async throws {
        let world = try await makeArchiveWorld()

        await #expect(throws: CycleArchiveFault.self) {
            try await CycleArchive().archive(world.featureContext)
        }

        #expect(try world.journal.inFlightCycleID() == world.cycleID)
    }
}

// MARK: - Land Act integration

@Suite("Land Act calls Cycle Archive only on an all-met verdict (P10.7)")
struct LandActCycleArchiveTests {
    @Test("An all-met verdict archives the Cycle; returnFeature is skipped; the next land Act is idle")
    func allMetVerdictArchivesAndTheNextActIsIdle() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID)
        let night = try journal.openNight(nightStart: landNightStart, mode: .real, act: .land, runID: runID).night
        try journal.recordFeatureVerification(NewFeatureVerification(
            featureID: land.featureID, cycleID: land.cycleID, route: nil, nightID: night.id, runID: runID,
            clauses: [archiveClause("c1", verdict: .met)]
        ))

        let log = LandCallLog()
        let allMetVerdict = VerificationVerdict(allClausesMet: true)
        let act = LandAct(
            mergeTest: StubMergeTest(log: log), push: StubPush(log: log), openPullRequest: StubPullRequest(log: log),
            verification: StubVerification(log: log, verdict: allMetVerdict),
            returnFeature: StubReturnFeature(log: log), archiveCycle: CycleArchive()
        )
        let outbox = Outbox(journal: journal, board: FakeWritingBoard(), runID: runID, act: .land, nightID: night.id)
        let context = ActContext(
            act: .land, mode: .real, trigger: .scheduled, runID: runID, journal: journal, night: night,
            outbox: outbox, mainlines: selectionMainlines(), repositories: selectionRepositories()
        )

        try await act.run(context)

        #expect(!log.all.contains("returnFeature"))
        let steps = try journal.events(ofType: .landStep).compactMap { record -> (LandStep, LandStepOutcome)? in
            guard case .landStep(let step, _, let outcome, _) = record.event else { return nil }
            return (step, outcome)
        }
        #expect(steps.contains { $0.0 == .archiveCycle && $0.1 == .completed })
        #expect(steps.contains { $0.0 == .returnFeature && $0.1 == .skipped })
        #expect(try journal.isCycleLanded(cycleID: land.cycleID))
        #expect(try journal.inFlightCycleID() == nil)

        // The next land Act firing finds no Feature in flight: idle.
        try journal.releaseActLease(runID: runID)
        let runID2 = RunID()
        try claimLandLease(journal, runID: runID2)
        let night2 = try journal.openNight(nightStart: landNightStart, mode: .real, act: .land, runID: runID2).night
        let outbox2 = Outbox(journal: journal, board: FakeWritingBoard(), runID: runID2, act: .land, nightID: night2.id)
        let context2 = ActContext(
            act: .land, mode: .real, trigger: .scheduled, runID: runID2, journal: journal, night: night2,
            outbox: outbox2, mainlines: selectionMainlines(), repositories: selectionRepositories()
        )
        try await act.run(context2)
        let idleEvents = try journal.events(ofType: .actIdle)
        #expect(idleEvents.contains { $0.event == .actIdle(reason: .noFeatureInFlight) })
    }
}

// MARK: - Author Act no longer skips once the Cycle is archived

@Suite("Author Act authors normally once the Cycle is archived (P10.7)")
struct AuthorActCycleArchiveTests {
    @Test("An archived Cycle (no Feature in flight) no longer records AuthoringSkippedFeatureInFlight")
    func authorsNormallyAfterArchival() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .blocked
        )
        try claimLandLease(journal, runID: runID)
        try journal.archiveCycle(cycleID: cycleID, featureID: featureID, closedBy: .verification, runID: runID)
        try journal.releaseActLease(runID: runID)

        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let gate = ScriptedPredecessorGate(outcome: .landed)
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        let invocation = EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: authorActNightStart, journal: journal,
            trigger: .scheduled, runID: RunID(), board: board,
            work: AuthorAct(predecessorGate: gate, authoring: authoring, unansweredNightsMax: 3).work
        )
        try await invocation.run()

        #expect(authoring.wasCalled)
        #expect(try journal.events().first { $0.type == .authoringSkippedFeatureInFlight } == nil)
    }
}

// MARK: - Archival does not release the next Feature: the predecessor-ancestry gate still holds authoring

@Suite("Archival alone does not clear the predecessor-ancestry gate (P10.7)")
struct CycleArchivePredecessorGateTests {
    @Test("An archived Feature whose branch is not merged into mainline still yields a quiet Night")
    func unmergedArchivedFeatureStillBlocksAuthoring() async throws {
        let backend = GateGitFixture(name: "archive-gate-backend")
        await backend.initRepo()
        _ = try await backend.commit(message: "init")
        _ = await backend.run(["checkout", "-b", "yh-proj-archived"])
        _ = try await backend.commit(filename: "feat.txt", content: "feat", message: "feature commit")
        _ = await backend.run(["checkout", "main"])
        // The Feature Branch is never merged: the archived, verified Feature is still unmerged mainline.

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-0", branch: "yh-proj-archived", repositories: ["backend"], inFlight: false
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertGateCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend")

        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: backend.path, role: .backend)
        ])
        let gate = PredecessorAncestryGate()
        let (context, _) = try makeGateContext(journal, repositories: repositories)

        let outcome = try await gate.check(context)

        guard case .notLanded(let predecessorIssueID, let unmergedRepositories) = outcome else {
            Issue.record("expected notLanded, got \(outcome)")
            return
        }
        #expect(predecessorIssueID == "FEAT-0")
        #expect(unmergedRepositories == ["backend"])
    }
}
