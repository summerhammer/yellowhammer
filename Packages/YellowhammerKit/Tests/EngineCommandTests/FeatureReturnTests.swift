import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Synchronization
import Testing

// roadmap P10.6 (spec: verification/return-a-feature-with-unmet-clauses): a Feature with any unmet or
// unresolved clause is returned to the Operator, holding those clauses named with their Spec Citations,
// not Done, its Cycle not archived, its already-opened pull requests linked and still open, idempotent
// across a retried land Act. Never asserts model-authored content.

private let returnEpoch = Date(timeIntervalSince1970: 1_800_000_000)
private let returnNightStart = NightStart(rawValue: "2026-09-16")!
private let returnBranch = FeatureBranch(rawValue: "yh-proj-feat")
private let returnOperator = BoardObjectID(rawValue: "user-1")

private func returnClause(
    _ cid: String, issue: String = "BACK-1", verdict: ClauseVerdict
) -> ClauseVerificationRecord {
    ClauseVerificationRecord(
        issueID: issue, cid: cid, level: "card", text: "Clause \(cid).", locationID: "epic/story",
        citationProvenance: "machine-found", verdict: verdict, whatWasChecked: "checked \(cid)",
        interpretation: "read \(cid)", judgedBy: verdict == .met ? .agent : .engine
    )
}

/// A Feature → Cycle → one Card world, with a real board wired (Waiting on You provisioned), for
/// ``FeatureReturn``'s own seam tests.
private final class ReturnWorld {
    let fixture: OutboxJournalFixture
    let journal: JournalStore
    let boards: NightCardTestBoards
    let context: ActContext
    let featureID: Int64
    let cycleID: Int64
    let feature: FeatureRecord
    let runID: RunID

    init(
        fixture: consuming OutboxJournalFixture, journal: JournalStore, boards: NightCardTestBoards,
        context: ActContext, featureID: Int64, cycleID: Int64, feature: FeatureRecord, runID: RunID
    ) {
        self.fixture = fixture
        self.journal = journal
        self.boards = boards
        self.context = context
        self.featureID = featureID
        self.cycleID = cycleID
        self.feature = feature
        self.runID = runID
    }

    var featureContext: LandActFeatureContext {
        LandActFeatureContext(act: context, feature: feature, cycleID: cycleID)
    }
}

private func makeReturnWorld() async throws -> ReturnWorld {
    let fixture = try OutboxJournalFixture()
    let journal = try fixture.open()
    let boards = try await makeBuildActBoards()
    await boards.writing.seed(issue: "FEAT-1", description: nil)
    let runID = RunID()
    try claimLandLease(journal, runID: runID)
    let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
    try journal.recordFeatureBranch(featureID: featureID, branch: returnBranch)
    let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
    _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .done)

    let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
    let night = try journal.openNight(nightStart: returnNightStart, mode: .real, act: .land, runID: runID).night
    let outbox = Outbox(
        journal: journal, board: boards.writing, runID: runID, act: .land, nightID: night.id, clock: { returnEpoch }
    )
    let context = ActContext(
        act: .land, mode: .real, trigger: .scheduled, runID: runID, journal: journal, night: night,
        outbox: outbox, board: board, mainlines: selectionMainlines(), repositories: selectionRepositories()
    )
    let (feature, _) = try #require(try journal.inFlightFeature())
    return ReturnWorld(
        fixture: fixture, journal: journal, boards: boards, context: context, featureID: featureID, cycleID: cycleID,
        feature: feature, runID: runID
    )
}

private func recordVerification(_ world: ReturnWorld, clauses: [ClauseVerificationRecord]) throws {
    try world.journal.recordFeatureVerification(NewFeatureVerification(
        featureID: world.featureID, cycleID: world.cycleID, route: nil, nightID: world.context.night.id,
        runID: world.runID, clauses: clauses
    ))
}

@Suite("Return a Feature with unmet clauses (P10.6)")
struct FeatureReturnTests {
    @Test("A Feature is returned: state 'returned', one featureReturned event, Waiting on You with no assignee")
    func returnsWithNoOperatorWired() async throws {
        let world = try await makeReturnWorld()
        try recordVerification(world, clauses: [returnClause("c1", verdict: .unmet), returnClause("c2", verdict: .met)])
        let verdict = VerificationVerdict(allClausesMet: false, unmetClauses: ["BACK-1 c1"])

        try await FeatureReturn(operatorIdentity: .none).returnFeature(world.featureContext, verdict: verdict)

        let feature = try #require(try world.journal.inFlightFeature()).feature
        #expect(feature.state == "returned")
        let events = try world.journal.events(ofType: .featureReturned)
        #expect(events.map(\.event) == [
            .featureReturned(cycleID: world.cycleID, featureIssueID: "FEAT-1", unmet: 1, unresolved: 0)
        ])

        let issue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "FEAT-1")))
        let scope = try await BoardStateScope.resolve(using: world.boards.provisioning)
        #expect(issue.workflowState == (try scope.id(for: .waitingOnYou)))
        #expect(issue.assignee == nil)

        let comment = try #require(await world.boards.writing.comments.first).body
        #expect(comment.contains("BACK-1 c1"))
        #expect(comment.contains("not Done"))

        // The Cycle stays open: not archived, still the in-flight Feature's Cycle.
        #expect(try world.journal.inFlightFeature()?.cycleID == world.cycleID)
    }

    @Test("Given an Operator, the Waiting on You write carries the assignment")
    func returnsWithOperatorAssigned() async throws {
        let world = try await makeReturnWorld()
        try recordVerification(world, clauses: [returnClause("c1", verdict: .unresolved)])
        let verdict = VerificationVerdict(allClausesMet: false, unresolvedClauses: ["BACK-1 c1"])

        let operatorIdentity = OperatorIdentity(configured: returnOperator)
        try await FeatureReturn(operatorIdentity: operatorIdentity)
            .returnFeature(world.featureContext, verdict: verdict)

        let issue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "FEAT-1")))
        #expect(issue.assignee == returnOperator)
    }

    @Test("A retry (the same land Act firing again) appends no second event and posts no second comment")
    func retryIsIdempotent() async throws {
        let world = try await makeReturnWorld()
        try recordVerification(world, clauses: [returnClause("c1", verdict: .unmet)])
        let verdict = VerificationVerdict(allClausesMet: false, unmetClauses: ["BACK-1 c1"])

        try await FeatureReturn(operatorIdentity: .none).returnFeature(world.featureContext, verdict: verdict)
        try await FeatureReturn(operatorIdentity: .none).returnFeature(world.featureContext, verdict: verdict)

        #expect(try world.journal.events(ofType: .featureReturned).count == 1)
        #expect(await world.boards.writing.comments.count == 1)
        #expect(try #require(try world.journal.inFlightFeature()).feature.state == "returned")
    }

    @Test("Pull requests already opened are linked from the return comment, as still open")
    func linksAlreadyOpenedPullRequests() async throws {
        let world = try await makeReturnWorld()
        try recordVerification(world, clauses: [returnClause("c1", verdict: .unmet)])
        try world.journal.recordPullRequest(
            featureID: world.featureID, repository: "backend",
            url: "https://github.com/summerhammer/backend/pull/9", nightID: world.context.night.id, runID: world.runID
        )
        let verdict = VerificationVerdict(allClausesMet: false, unmetClauses: ["BACK-1 c1"])

        try await FeatureReturn(operatorIdentity: .none).returnFeature(world.featureContext, verdict: verdict)

        let comment = try #require(await world.boards.writing.comments.first).body
        #expect(comment.contains("https://github.com/summerhammer/backend/pull/9"))
        #expect(comment.contains("still open"))
    }

    @Test("With no recorded Verification, returning the Feature faults")
    func faultsWithoutARecordedVerification() async throws {
        let world = try await makeReturnWorld()
        let verdict = VerificationVerdict(allClausesMet: false, unmetClauses: ["BACK-1 c1"])

        await #expect(throws: FeatureReturnFault.self) {
            try await FeatureReturn(operatorIdentity: .none).returnFeature(world.featureContext, verdict: verdict)
        }
    }
}

// MARK: - Land Act integration

@Suite("Land Act calls Feature Return only on an unmet verdict (P10.6)")
struct LandActFeatureReturnTests {
    @Test("An unmet verdict returns the Feature; the Cycle stays unarchived; archiveCycle is skipped")
    func unmetVerdictReturnsAndSkipsArchive() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID)
        let night = try journal.openNight(nightStart: landNightStart, mode: .real, act: .land, runID: runID).night
        try journal.recordFeatureVerification(NewFeatureVerification(
            featureID: land.featureID, cycleID: land.cycleID, route: nil, nightID: night.id, runID: runID,
            clauses: [returnClause("c1", verdict: .unmet)]
        ))

        let log = LandCallLog()
        let unmetVerdict = VerificationVerdict(allClausesMet: false, unmetClauses: ["BACK-1 c1"])
        let act = LandAct(
            mergeTest: StubMergeTest(log: log), push: StubPush(log: log), openPullRequest: StubPullRequest(log: log),
            verification: StubVerification(log: log, verdict: unmetVerdict),
            returnFeature: FeatureReturn(operatorIdentity: .none), archiveCycle: StubArchiveCycle(log: log)
        )
        let outbox = Outbox(journal: journal, board: FakeWritingBoard(), runID: runID, act: .land, nightID: night.id)
        let context = ActContext(
            act: .land, mode: .real, trigger: .scheduled, runID: runID, journal: journal, night: night,
            outbox: outbox, mainlines: selectionMainlines(), repositories: selectionRepositories()
        )

        try await act.run(context)

        #expect(!log.all.contains("archiveCycle"))
        let steps = try journal.events(ofType: .landStep).compactMap { record -> (LandStep, LandStepOutcome)? in
            guard case .landStep(let step, _, let outcome, _) = record.event else { return nil }
            return (step, outcome)
        }
        #expect(steps.contains { $0.0 == .returnFeature && $0.1 == .completed })
        #expect(steps.contains { $0.0 == .archiveCycle && $0.1 == .skipped })
        #expect(try journal.isCycleLanded(cycleID: land.cycleID))
        let feature = try #require(try journal.inFlightFeature())
        #expect(feature.cycleID == land.cycleID)
        #expect(feature.feature.state == "returned")
    }

    @Test("An all-met verdict never calls Feature Return: the Feature's state is untouched")
    func allMetVerdictNeverReturns() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID)
        let night = try journal.openNight(nightStart: landNightStart, mode: .real, act: .land, runID: runID).night
        let stateBefore = try #require(try journal.inFlightFeature()).feature.state

        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log), push: StubPush(log: log), openPullRequest: StubPullRequest(log: log),
            verification: StubVerification(log: log, verdict: VerificationVerdict(allClausesMet: true)),
            returnFeature: StubReturnFeature(log: log), archiveCycle: StubArchiveCycle(log: log)
        )
        let outbox = Outbox(journal: journal, board: FakeWritingBoard(), runID: runID, act: .land, nightID: night.id)
        let context = ActContext(
            act: .land, mode: .real, trigger: .scheduled, runID: runID, journal: journal, night: night,
            outbox: outbox, mainlines: selectionMainlines(), repositories: selectionRepositories()
        )

        try await act.run(context)

        #expect(!log.all.contains("returnFeature"))
        #expect(log.all.contains("archiveCycle"))
        #expect(try #require(try journal.inFlightFeature()).feature.state == stateBefore)
    }

    @Test("A Partial Landing (a Blocked Card) always returns the Feature — no special-casing")
    func partialLandingReturnsTheFeature() async throws {
        let world = try await VerificationWorld(
            cards: [VerificationCard("BACK-1", "backend", .done), VerificationCard("MOB-1", "mobile", .blocked)]
        )
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addClause(issue: "MOB-1", cid: "c1")
        for repository in ["backend", "mobile"] {
            try world.journal.recordWorktree(
                featureID: world.featureID, repository: repository, worktreeID: "wt-\(repository)",
                path: "/tmp/\(repository)", runID: world.featureContext.act.runID
            )
        }
        let log = LandCallLog()
        let verification = FeatureVerification(
            resolver: verificationResolver(primary: routeOther), dispatch: RehearsalDispatch(),
            citations: FakeCitationResolver()
        )
        let act = LandAct(
            mergeTest: StubMergeTest(log: log), push: StubPush(log: log), openPullRequest: StubPullRequest(log: log),
            verification: verification, returnFeature: FeatureReturn(operatorIdentity: .none),
            archiveCycle: StubArchiveCycle(log: log)
        )

        try await act.run(world.featureContext.act)

        #expect(!log.all.contains("archiveCycle"))
        let feature = try #require(try world.journal.inFlightFeature()).feature
        #expect(feature.state == "returned")
        #expect(try world.journal.inFlightFeature()?.cycleID == world.cycleID)
    }
}

// MARK: - Author Act skips a Project whose Feature is returned

@Suite("Author Act skips authoring while a Feature is returned (P10.6)")
struct AuthorActFeatureReturnTests {
    @Test("A returned Feature (Cycle still open) still skips authoring, naming that Feature")
    func skipsWhenReturnedFeatureInFlight() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .blocked
        )
        try claimLandLease(journal, runID: runID)
        try journal.recordFeatureReturned(featureID: featureID, runID: runID)
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

        #expect(!authoring.wasCalled)
        let skipEvent = try #require(
            try journal.events().first { $0.type == .authoringSkippedFeatureInFlight }
        )
        guard case .authoringSkippedFeatureInFlight(let issueID) = skipEvent.event else {
            Issue.record("expected authoringSkippedFeatureInFlight")
            return
        }
        #expect(issueID == "FEAT-1")
    }

    @Test("A separate Project with no in-flight Feature authors normally")
    func otherProjectAuthorsNormally() async throws {
        let fixture = try OutboxJournalFixture(project: "other")
        let journal = try fixture.open()
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
