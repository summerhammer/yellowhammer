import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Repositories
import Testing

// roadmap P8.2: the Readiness Check at dispatch. Each scenario runs a rehearsal build Act over a
// fixture Feature with two Cards in one lane, so "the lane moves on to its next Card" is observable
// through `RecordingCardRunner`. Fixture helpers here are shared with ReadinessCheckTests+Board.swift.

let readinessNightStart = NightStart(rawValue: "2026-09-17")!
let readinessEpoch = Date()
private let backendRepo = Repo(name: "backend", path: "/nonexistent/backend", role: .backend)
let readinessRepositories = ProjectRepositories(workingRepos: [backendRepo])

/// Everything one scenario needs: the Journal, the two Cards' ids, the recorder, and the board so a
/// scenario can seed a description before running.
struct ReadinessScenario {
    let directory: URL
    let journal: JournalStore
    let cardOne: Int64
    let cardTwo: Int64
    let issueOne: String
    let issueTwo: String
    let boards: NightCardTestBoards
    let recorder: RecordingCardRunner
}

/// Removes the scenario's Journal directory. Every scenario test calls this in a `defer`, because the
/// scenario is built once and reused across several act runs within the same test.
func cleanup(_ scenario: ReadinessScenario) {
    try? FileManager.default.removeItem(at: scenario.directory)
}

/// Seeds a Feature → Cycle → two backend Cards, with the second always Ready to dispatch (a brief, one
/// clause with a resolvable citation), so a scenario only has to set up the first Card's readiness.
func makeReadinessScenario() async throws -> ReadinessScenario {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-readiness-\(UUID().uuidString)", directoryHint: .isDirectory)
    let projectID = try #require(ProjectID(rawValue: "fixture"))
    let journal = try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: readinessEpoch)
    else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    try journal.releaseActLease(runID: runID)

    let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-READY")
    try journal.recordFeatureBranch(featureID: featureID, branch: FeatureBranch(rawValue: "yh-proj-ready"))
    let cycleID = try insertReconcilerCycle(journal, featureID: featureID)

    let issueOne = "READY-1"
    let issueTwo = "READY-2"
    let cardOne = try insertReconcilerCard(
        journal, cycleID: cycleID, issueID: issueOne, repository: "backend", state: .todo
    )
    let cardTwo = try insertReconcilerCard(
        journal, cycleID: cycleID, issueID: issueTwo, repository: "backend", state: .todo
    )

    try journal.recordArchitecturalBrief(cardID: cardTwo, prose: "Second Card's brief.")
    try journal.insertClause(JournalStore.NewClause(
        cid: "c1", issueID: issueTwo, level: "card", text: "Second Card's clause",
        locationID: "resolvable/story", provenance: "Author-supplied", citationProvenance: "Author-supplied"
    ))

    let boards = try await makeBuildActBoards()
    await boards.writing.seed(issue: issueOne, description: nil)
    await boards.writing.seed(issue: issueTwo, description: nil)

    let recorder = RecordingCardRunner()

    return ReadinessScenario(
        directory: directory, journal: journal, cardOne: cardOne, cardTwo: cardTwo, issueOne: issueOne,
        issueTwo: issueTwo, boards: boards, recorder: recorder
    )
}

/// Runs the build Act with a given readiness check and an optional Delta Read page of board objects
/// (for reconciliation scenarios). Returns after the invocation completes.
func runReadinessAct(
    _ scenario: ReadinessScenario, readiness: ReadinessCheck, updatedObjects: [BoardObject] = []
) async throws {
    let reading = FakeReadingBoard([page(objects: updatedObjects)])
    let board = ActBoard(
        reading: reading, writing: scenario.boards.writing, provisioning: scenario.boards.provisioning
    )
    let invocation = EngineInvocation(
        act: .build, mode: .rehearsal, nightStart: readinessNightStart, journal: scenario.journal,
        trigger: .scheduled, runID: RunID(), board: board, repositories: readinessRepositories,
        work: BuildAct(cardRunner: scenario.recorder, readiness: readiness).work
    )
    try await invocation.run()
}

/// Calls `ReadinessCheck.evaluate` directly against the scenario's Journal, under a fresh claim of the
/// Act lease and a fresh Night — for re-checking a Card that a lane would no longer consider runnable
/// (Waiting on You, Blocked), the way a later Act's pass over it would.
func directEvaluate(
    _ scenario: ReadinessScenario, cardID: Int64, readiness: ReadinessCheck
) async throws -> ReadinessVerdict {
    let runID = RunID()
    guard case .claimed = try scenario.journal.claimActLease(act: .build, runID: runID, mode: .rehearsal) else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    defer { _ = try? scenario.journal.releaseActLease(runID: runID) }
    let opening = try scenario.journal.openNight(
        nightStart: readinessNightStart, mode: .rehearsal, act: .build, runID: runID
    )
    let (feature, cycleID) = try #require(try scenario.journal.inFlightFeature())
    let card = try scenario.journal.card(id: cardID)

    let act = ActContext(
        act: .build, mode: .rehearsal, trigger: .scheduled, runID: runID, journal: scenario.journal,
        night: opening.night, repositories: readinessRepositories
    )
    let context = BuildActContext(
        act: act, feature: feature, cycleID: cycleID, reconciliation: WorktreeReconciliation(), deltaRead: nil
    )
    return try await readiness.evaluate(card: card, context: context)
}

@Test("A Card with no Architectural Brief fails readiness; the lane moves on")
func briefMissingFailsReadiness() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    let readiness = ReadinessCheck(provenance: FakeProvenanceTester(), citations: FakeCitationResolver())

    try await runReadinessAct(scenario, readiness: readiness)

    let events = try scenario.journal.events(ofType: .readinessCheckFailed)
    #expect(events.count == 1)
    guard case .readinessCheckFailed(_, let issueID, let failures) = events[0].event else {
        Issue.record("expected readinessCheckFailed")
        return
    }
    #expect(issueID == scenario.issueOne)
    #expect(failures.contains { $0.contains("no Architectural Brief") })

    #expect(scenario.recorder.seen.map(\.issueID) == [scenario.issueTwo])

    let laneEnded = try scenario.journal.events(ofType: .repoLaneEnded)
    guard case .repoLaneEnded(_, let cardsRun, _, let cardsSkipped) = laneEnded[0].event else {
        Issue.record("expected repoLaneEnded")
        return
    }
    #expect(cardsRun == 1)
    #expect(cardsSkipped == 1)

    let attempts = try scenario.journal.attemptHistory(cardID: scenario.cardOne)
    #expect(attempts.attempts.isEmpty)
}

@Test("A Card with a brief but no Definition of Done fails readiness")
func definitionOfDoneMissingFailsReadiness() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try scenario.journal.recordArchitecturalBrief(cardID: scenario.cardOne, prose: "A brief with no clauses.")
    let readiness = ReadinessCheck(provenance: FakeProvenanceTester(), citations: FakeCitationResolver())

    try await runReadinessAct(scenario, readiness: readiness)

    let events = try scenario.journal.events(ofType: .readinessCheckFailed)
    guard case .readinessCheckFailed(_, _, let failures) = events[0].event else {
        Issue.record("expected readinessCheckFailed")
        return
    }
    #expect(failures.contains { $0.contains("no Definition of Done") })
}

@Test("A clause whose citation does not resolve fails readiness")
func citationUnresolvedFailsReadiness() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try scenario.journal.recordArchitecturalBrief(cardID: scenario.cardOne, prose: "A brief.")
    try scenario.journal.insertClause(JournalStore.NewClause(
        cid: "c1", issueID: scenario.issueOne, level: "card", text: "A clause",
        locationID: "unresolvable/story", provenance: "Author-supplied", citationProvenance: "Author-supplied"
    ))
    let readiness = ReadinessCheck(
        provenance: FakeProvenanceTester(), citations: FakeCitationResolver(resolvable: ["resolvable/story"])
    )

    try await runReadinessAct(scenario, readiness: readiness)

    let events = try scenario.journal.events(ofType: .readinessCheckFailed)
    guard case .readinessCheckFailed(_, _, let failures) = events[0].event else {
        Issue.record("expected readinessCheckFailed")
        return
    }
    #expect(failures.contains { $0.contains("unresolvable/story") })
}

@Test("A Ready Card is dispatched, carrying its brief and clauses to the CardRunner")
func readyCardIsDispatched() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try scenario.journal.recordArchitecturalBrief(cardID: scenario.cardOne, prose: "A brief.")
    try scenario.journal.insertClause(JournalStore.NewClause(
        cid: "c1", issueID: scenario.issueOne, level: "card", text: "A clause",
        locationID: "resolvable/story", provenance: "Author-supplied", citationProvenance: "Author-supplied"
    ))
    let readiness = ReadinessCheck(
        provenance: FakeProvenanceTester(), citations: FakeCitationResolver(resolvable: ["resolvable/story"])
    )

    try await runReadinessAct(scenario, readiness: readiness)

    let passed = try scenario.journal.events(ofType: .readinessCheckPassed)
    #expect(passed.count == 2)
    #expect(scenario.recorder.seen.map(\.issueID) == [scenario.issueOne, scenario.issueTwo])

    let laneEnded = try scenario.journal.events(ofType: .repoLaneEnded)
    guard case .repoLaneEnded(_, let cardsRun, _, let cardsSkipped) = laneEnded[0].event else {
        Issue.record("expected repoLaneEnded")
        return
    }
    #expect(cardsRun == 2)
    #expect(cardsSkipped == 0)
}

@Test("evaluate never throws for a readiness outcome, and records events with no Outbox")
func evaluateNeverThrowsWithNoOutbox() async throws {
    let fixture = try OutboxJournalFixture()
    let journal = try fixture.open()
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: readinessEpoch)
    else {
        Issue.record("could not claim lease")
        return
    }
    let opening = try journal.openNight(nightStart: readinessNightStart, mode: .rehearsal, act: .build, runID: runID)

    let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-UNIT")
    let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
    let cardID = try insertReconcilerCard(
        journal, cycleID: cycleID, issueID: "UNIT-1", repository: "backend", state: .todo
    )
    let card = try #require(try journal.card(issueID: "UNIT-1"))
    let (feature, inFlightCycleID) = try #require(try journal.inFlightFeature())

    let act = ActContext(
        act: .build, mode: .rehearsal, trigger: .scheduled, runID: runID, journal: journal, night: opening.night,
        repositories: readinessRepositories
    )
    let buildContext = BuildActContext(
        act: act, feature: feature, cycleID: inFlightCycleID,
        reconciliation: WorktreeReconciliation(), deltaRead: nil
    )
    let readiness = ReadinessCheck(provenance: FakeProvenanceTester(), citations: FakeCitationResolver())

    let verdict = try await readiness.evaluate(card: card, context: buildContext)
    guard case .notReady = verdict else {
        Issue.record("expected notReady")
        return
    }
    #expect(try journal.events(ofType: .readinessCheckFailed).count == 1)
    _ = cardID
}
