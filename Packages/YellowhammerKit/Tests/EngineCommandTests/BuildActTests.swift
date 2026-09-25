import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Synchronization
import Testing

// roadmap P8.1: the build Act's work, in order — sweep expired Card Leases, reconcile Worktrees,
// repost board state, perform the Delta Read, derive Repo Lanes, run them concurrently (each lane's
// Cards one at a time, in authored order), write back. Every step leaves a record in the event log.

// Shared with BuildActTests+Worktrees.swift, so not fileprivate.
let buildActNightStart = NightStart(rawValue: "2026-09-15")!
// `ExpiredLeaseSweep`'s default clock is the real wall clock (it is never injected here), so every
// lease timestamp in these fixtures is relative to `Date()`, not a fixed epoch.
let buildActEpoch = Date()
let buildActBranch = FeatureBranch(rawValue: "yh-proj-feat")

/// Seeds the states `makeBoards()` does not: In Progress, Blocked and Waiting on You (mirroring
/// BoardStateProjectionTests' `makeProjectionBoards`).
func makeBuildActBoards() async throws -> NightCardTestBoards {
    let boards = try await makeBoards()
    await boards.provisioning.seed(state: "In Progress", team: teamID, category: .started)
    await boards.provisioning.seed(state: "Blocked", team: teamID, category: .unstarted)
    await boards.provisioning.seed(state: "Waiting on You", team: teamID, category: .unstarted)
    return boards
}

/// Records every Card a lane handed it, in the order it saw them; can be scripted to throw for a
/// repository's Cards.
final class RecordingCardRunner: CardRunner, Sendable {
    private struct State {
        var seen: [(repository: String, issueID: String)] = []
        var throwing: Set<String> = []
    }

    private let state = Mutex(State())

    init(throwingFor repositories: Set<String> = []) {
        state.withLock { $0.throwing = repositories }
    }

    var seen: [(repository: String, issueID: String)] { state.withLock { $0.seen } }

    func run(card: CardRecord, in lane: RepoLane, context: BuildActContext, readiness: CardReadiness) async throws {
        state.withLock { $0.seen.append((lane.repository, card.issueID)) }
        if state.withLock({ $0.throwing.contains(lane.repository) }) {
            throw BuildActTestRunnerError()
        }
    }
}

struct BuildActTestRunnerError: Error, Equatable {}

@Suite("Build Act")
struct BuildActTests {
    @Test("A rehearsal build Act over a fixture Feature performs the steps in order, as recorded in the event log")
    // The scenario is the length: a full fixture, then every assertion the story names.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func buildActPerformsStepsInOrder() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }

        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordFeatureBranch(featureID: featureID, branch: buildActBranch)
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)

        let backend1 = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo
        )
        let backend2 = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend", state: .todo
        )
        let backend3 = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-3", repository: "backend", state: .done
        )
        let mobile1 = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile", state: .blocked
        )
        let mobile2 = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "MOB-2", repository: "mobile", state: .todo
        )

        // Every Card but BACK-2 is already posted to the board; only BACK-2 is left for repost to post:
        // Blocked and back to Todo in the Journal, and the board never confirmed either write.
        for cardID in [backend1, backend3, mobile1, mobile2] {
            try journal.recordCardBoardState(cardID: cardID, version: 0, runID: runID, now: buildActEpoch)
        }
        _ = try journal.transitionCard(
            cardID: backend2, to: .blocked, blockReason: .unanswered, runID: runID, act: .build, nightID: nil,
            now: buildActEpoch
        )
        _ = try journal.transitionCard(
            cardID: backend2, to: .todo, runID: runID, act: .build, nightID: nil, now: buildActEpoch
        )
        // repost() now claims each unposted Card's Lease itself for the replay (#81); no pre-claim needed.

        // A dead run's expired Card Lease on BACK-1: claimed, then never heartbeated past the TTL (600s).
        let deadRun = RunID()
        _ = try journal.claimCardLease(cardID: backend1, runID: deadRun, now: buildActEpoch.addingTimeInterval(-700))

        let boards = try await makeBuildActBoards()
        for issueID in ["BACK-1", "BACK-2", "BACK-3", "MOB-1", "MOB-2"] {
            await boards.writing.seed(issue: issueID, description: nil)
        }
        let reading = FakeReadingBoard([page(objects: [object("MOB-2", state: stateCancelled)])])
        let board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)

        let recorder = RecordingCardRunner()
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, board: board, work: BuildAct(cardRunner: recorder).work
        )

        try await invocation.run()

        let events = try journal.events()
        let relevantTypes: Set<JournalEventType> = [
            .cardLeaseReclaimed, .expiredCardLeasesSwept, .boardStateReposted, .cardCancelled,
            .deltaReadCompleted, .repoLanesDerived, .repoLaneStarted, .repoLaneEnded, .actEnded
        ]
        let relevant = events.filter { relevantTypes.contains($0.type) }
        let order = relevant.map(\.type)

        func index(of type: JournalEventType) -> Int? { order.firstIndex(of: type) }

        #expect(index(of: .cardLeaseReclaimed) != nil)
        #expect(index(of: .expiredCardLeasesSwept) != nil)
        #expect(index(of: .boardStateReposted) != nil)
        #expect(index(of: .cardCancelled) != nil)
        #expect(index(of: .deltaReadCompleted) != nil)
        #expect(index(of: .repoLanesDerived) != nil)
        #expect(order.filter { $0 == .repoLaneStarted }.count == 2)
        #expect(order.filter { $0 == .repoLaneEnded }.count == 2)

        // Order: lease sweep before repost, repost before the Delta Read, the Delta Read before lanes.
        #expect(index(of: .cardLeaseReclaimed)! < index(of: .expiredCardLeasesSwept)!)
        #expect(index(of: .expiredCardLeasesSwept)! < index(of: .boardStateReposted)!)
        #expect(index(of: .boardStateReposted)! < index(of: .cardCancelled)!)
        #expect(index(of: .cardCancelled)! < index(of: .deltaReadCompleted)!)
        #expect(index(of: .deltaReadCompleted)! < index(of: .repoLanesDerived)!)
        #expect(index(of: .repoLanesDerived)! < order.firstIndex(of: .repoLaneStarted)!)
        #expect(order.last == .actEnded)
        // Both lanes started before the Act ended, and each lane ended after it started.
        for start in order.indices where order[start] == .repoLaneStarted {
            #expect(start < order.count - 1)
        }

        guard case .expiredCardLeasesSwept(let sweptCycleID, let reclaimed) = try #require(
            events.first { $0.type == .expiredCardLeasesSwept }?.event
        ) else {
            Issue.record("expected expiredCardLeasesSwept")
            return
        }
        #expect(sweptCycleID == cycleID)
        #expect(reclaimed == [backend1])

        guard case .boardStateReposted(let posted) = try #require(
            events.first { $0.type == .boardStateReposted }?.event
        ) else {
            Issue.record("expected boardStateReposted")
            return
        }
        #expect(posted == 1)

        guard case .repoLanesDerived(_, let lanes) = try #require(
            events.first { $0.type == .repoLanesDerived }?.event
        ) else {
            Issue.record("expected repoLanesDerived")
            return
        }
        #expect(lanes == ["backend", "mobile"])

        // The runner saw backend #1 then backend #2, and nothing from mobile (mobile #1 is Blocked,
        // mobile #2 was cancelled by the Delta Read).
        #expect(recorder.seen.map(\.issueID) == ["BACK-1", "BACK-2"])

        guard let mobileEnded = events.first(where: {
            if case .repoLaneEnded(let repository, _, _, _) = $0.event { return repository == "mobile" }
            return false
        })?.event, case .repoLaneEnded(_, let mobileCardsRun, _, _) = mobileEnded else {
            Issue.record("expected repoLaneEnded for mobile")
            return
        }
        #expect(mobileCardsRun == 0)

        guard let mobileStarted = events.first(where: {
            if case .repoLaneStarted(let repository, _) = $0.event { return repository == "mobile" }
            return false
        })?.event, case .repoLaneStarted(_, let mobileRunnableCount) = mobileStarted else {
            Issue.record("expected repoLaneStarted for mobile")
            return
        }
        #expect(mobileRunnableCount == 0)

        // The Act's own Lease is released, and the reclaimed Card's Lease is released too.
        #expect(try journal.currentActLease() == nil)
        let backend1Lease = try journal.currentCardLease(cardID: backend1)
        #expect(backend1Lease == nil || !backend1Lease!.isHeld(at: buildActEpoch.addingTimeInterval(1)))
    }

    // "Worktree reconciliation runs after the lease sweep and before the board repost" and "Held
    // Worktrees with no recorded Feature Branch stop the Act" live in BuildActTests+Worktrees.swift,
    // split out to keep this file under the file length limit.

    @Test("A degraded Delta Read does less work: no lanes derived, no Card run")
    func degradedDeltaReadDoesLessWork() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordFeatureBranch(featureID: featureID, branch: buildActBranch)
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo)

        let boards = try await makeBuildActBoards()
        await boards.writing.seed(issue: "BACK-1", description: nil)
        let reading = FakeReadingBoard([.failure(.rateLimited(retryAfter: nil, budget: nil))])
        let board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)

        let recorder = RecordingCardRunner()
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, board: board, work: BuildAct(cardRunner: recorder).work
        )

        try await invocation.run()

        #expect(try journal.events(ofType: .repoLanesDerived).isEmpty)
        #expect(recorder.seen.isEmpty)
        #expect(try journal.events(ofType: .rateBudgetExhausted).count == 1)
        #expect(try journal.events(ofType: .actEnded).count == 1)
    }

    @Test("A lane that fails does not stop the other lanes")
    func oneFailingLaneDoesNotStopTheOthers() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordFeatureBranch(featureID: featureID, branch: buildActBranch)
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile", state: .todo)

        let recorder = RecordingCardRunner(throwingFor: ["mobile"])
        // No Board bound: this test is about lane concurrency, not board projection.
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, work: BuildAct(cardRunner: recorder).work
        )

        await #expect(throws: BuildActError.self) {
            try await invocation.run()
        }

        #expect(recorder.seen.contains { $0.issueID == "BACK-1" })
        let mobileEndedEvents = try journal.events(ofType: .repoLaneEnded).filter {
            if case .repoLaneEnded(let repository, _, _, _) = $0.event { return repository == "mobile" }
            return false
        }
        #expect(mobileEndedEvents.count == 1)
        guard case .repoLaneEnded(_, let cardsRun, let failure, _) = mobileEndedEvents[0].event else {
            Issue.record("expected repoLaneEnded")
            return
        }
        #expect(cardsRun == 0)
        #expect(failure != nil)
        #expect(try journal.events(ofType: .actIncomplete).count == 1)
        #expect(try journal.currentActLease() == nil)
    }

    @Test("With no Board bound the board steps are skipped and lanes still run")
    func noBoardSkipsBoardStepsButRunsLanes() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordFeatureBranch(featureID: featureID, branch: buildActBranch)
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo)

        let recorder = RecordingCardRunner()
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, work: BuildAct(cardRunner: recorder).work
        )

        try await invocation.run()

        #expect(try journal.events(ofType: .boardStateReposted).isEmpty)
        #expect(try journal.events(ofType: .deltaReadCompleted).isEmpty)
        #expect(try journal.events(ofType: .repoLanesDerived).count == 1)
        #expect(recorder.seen.map(\.issueID) == ["BACK-1"])
    }
}

@Suite("RepoLane.derive")
struct RepoLaneDeriveTests {
    @Test("Cards group by repository, each lane's Cards in authored order, lanes sorted by repository name")
    func groupsAndOrders() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let mobile2 = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "MOB-2", repository: "mobile", state: .todo
        )
        let backend2 = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend", state: .todo
        )
        let backend1 = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo
        )
        let mobile1 = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile", state: .todo
        )

        let cards = try journal.cards(cycleID: cycleID)
        let lanes = RepoLane.derive(from: cards)
        #expect(lanes.map(\.repository) == ["backend", "mobile"])
        // backend2 and mobile2 were each authored first in their repository, so authored_order sorts
        // them before backend1 and mobile1 respectively.
        #expect(lanes[0].cards.map(\.id) == [backend2, backend1])
        #expect(lanes[1].cards.map(\.id) == [mobile2, mobile1])
    }

    @Test("runnable filters to Todo only")
    func runnableFiltersToTodo() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let todo = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo
        )
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend", state: .done)
        _ = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-3", repository: "backend", state: .blocked
        )

        let lane = RepoLane.derive(from: try journal.cards(cycleID: cycleID))[0]
        #expect(lane.runnable.map(\.id) == [todo])
    }

    @Test("No Cards yields no lanes")
    func noCardsYieldsNoLanes() {
        #expect(RepoLane.derive(from: []).isEmpty)
    }
}
