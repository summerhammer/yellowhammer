import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

private struct RecoveryFixture: ~Copyable {
    let directory = FileManager.default.temporaryDirectory.appending(component: "yh-pulse-recovery-\(UUID())")
    let projectID = ProjectID(rawValue: "recovery")! // swiftlint:disable:this force_unwrapping

    deinit { try? FileManager.default.removeItem(at: directory) }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let featureName = "Feature"
private let overBudget = "Work Card \"T\" (backend) composes 12,153 UTF-16 code units, over the description budget "
    + "of 10,000: Brief 7,000"
private let scopeReason = "The Project's board scope is unresolved, so this Act did no work."

private func tick(_ seconds: Int) -> Date { epoch.addingTimeInterval(TimeInterval(seconds)) }

private func selected() -> JournalEvent {
    .featureSelected(FeatureSelectedPayload(
        name: featureName, reasoning: "next", precededBy: nil, followedBy: nil, seam: nil,
        repositories: ["backend"], adoptedCardIssueIDs: [], unadoptedCardIssueIDs: []
    ))
}

private func authored() -> JournalEvent {
    .featureAuthored(FeatureAuthoredPayload(
        name: featureName, groupKey: "g", featureIssueID: UUID().uuidString, cycleID: 1, cardCount: 1,
        adoptedCount: 0
    ))
}

private func accepted() -> JournalEvent {
    .featureAuthoringAccepted(FeatureAuthoringAcceptedPayload(
        name: featureName, groupKey: "g", featureKey: "f", nightID: 1, cards: [], adoptions: []
    ))
}

/// Appends `steps` as runs of one Night: each is (act, run index, event); times follow the order given.
private struct Night {
    let journal: JournalStore
    let nightID: Int64
    var runs: [RunID] = []
    var clock = 0

    init(_ journal: JournalStore) throws {
        self.journal = journal
        let first = RunID()
        _ = try journal.claimActLease(act: .author, runID: first, mode: .real, now: epoch)
        nightID = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: first, now: epoch)
            .night.id
        runs = [first]
    }

    mutating func run() -> Int {
        runs.append(RunID())
        return runs.count - 1
    }

    mutating func add(_ event: JournalEvent, act: Act = .author, run: Int) throws {
        clock += 10
        try journal.append(event, act: act, runID: runs[run], nightID: nightID, now: tick(clock))
    }

    func read() throws -> PulseSnapshot {
        try PulseSnapshot.read(from: journal, status: .idle, asOf: tick(clock + 1))
    }
}

@Suite("Recovery of Act failures by cause")
struct PulseFailureRecoveryTests {
    @Test("A later over-budget fault for the same Feature does not recover the earlier one")
    func laterSameCauseDoesNotRecover() throws {
        let fixture = RecoveryFixture()
        var night = try Night(fixture.open())
        try night.add(.featureBreakdownRejected(name: featureName, reason: overBudget), run: 0)
        let second = night.run()
        try night.add(selected(), run: second)
        try night.add(.featureBreakdownRejected(name: featureName, reason: overBudget), run: second)

        let flag = try #require(try night.read().health?.first)
        #expect(flag.cause == .overDescriptionBudget)
        #expect(flag.recoveredAt == nil)
    }

    @Test("Accepted then a transaction failure recovers over budget and stands as its own failure")
    func transactionFailureRecoversOverBudget() throws {
        let fixture = RecoveryFixture()
        var night = try Night(fixture.open())
        try night.add(.featureBreakdownRejected(name: featureName, reason: overBudget), run: 0)
        let second = night.run()
        try night.add(accepted(), run: second)
        try night.add(.featureAuthoringFailed(name: featureName, groupKey: "g", reason: "rolled back"), run: second)

        let flags = try #require(try night.read().health)
        let over = try #require(flags.first { $0.cause == .overDescriptionBudget })
        let transaction = try #require(flags.first { $0.cause == .authoringTransactionFailed })
        #expect(over.recoveredAt != nil)
        #expect(transaction.recoveredAt == nil)
    }

    @Test("A build run's post-preflight event recovers an author board-scope failure")
    func buildRunRecoversBoardScope() throws {
        let fixture = RecoveryFixture()
        var night = try Night(fixture.open())
        try night.add(.actIncomplete(reason: scopeReason), run: 0)
        let build = night.run()
        try night.add(.actStarted, act: .build, run: build)
        try night.add(.linearReached, act: .build, run: build)
        try night.add(.actIdle(reason: .noFeatureInFlight), act: .build, run: build)

        let flag = try #require(try night.read().health?.first)
        #expect(flag.cause == .boardScopeUnresolved)
        #expect(flag.recoveredAt == tick(40))
        #expect(!flag.canRepairBoard)
    }

    @Test("A later run that fails on the board scope again does not recover it")
    func repeatedBoardScopeDoesNotRecover() throws {
        let fixture = RecoveryFixture()
        var night = try Night(fixture.open())
        try night.add(.actIncomplete(reason: scopeReason), run: 0)
        let second = night.run()
        try night.add(.actStarted, run: second)
        try night.add(.linearReached, run: second)
        try night.add(.boardScopeUnresolved(steps: "label"), run: second)
        try night.add(.actIncomplete(reason: scopeReason), run: second)

        let flag = try #require(try night.read().health?.first)
        #expect(flag.recoveredAt == nil)
        #expect(flag.canRepairBoard)
    }

    @Test("Selected then an invalid breakdown does not recover over budget")
    func invalidBreakdownDoesNotRecoverOverBudget() throws {
        let fixture = RecoveryFixture()
        var night = try Night(fixture.open())
        try night.add(.featureBreakdownRejected(name: featureName, reason: overBudget), run: 0)
        let second = night.run()
        try night.add(selected(), run: second)
        try night.add(.featureBreakdownRejected(name: featureName, reason: "bad range"), run: second)

        let flags = try #require(try night.read().health)
        #expect(flags.first { $0.cause == .overDescriptionBudget }?.recoveredAt == nil)
        #expect(flags.first { $0.cause == .invalidBreakdown } != nil)
    }

    @Test("A later featureSelected recovers selectionFailed")
    func selectionRecovers() throws {
        let fixture = RecoveryFixture()
        var night = try Night(fixture.open())
        try night.add(.featureSelectionFailed(reason: "none fit"), run: 0)
        let second = night.run()
        try night.add(selected(), run: second)

        let flag = try #require(try night.read().health?.first)
        #expect(flag.cause == .selectionFailed)
        #expect(flag.detail == "author: selecting a Feature failed: none fit")
        #expect(flag.recoveredAt == tick(20))
    }

    @Test("An invariant break is never recovered and links to its Card")
    func invariantNeverRecovers() throws {
        let fixture = RecoveryFixture()
        var night = try Night(fixture.open())
        try night.add(.authoringInvariantBroken(cardID: 1, issueID: "card-1", reason: "broken"), run: 0)
        let second = night.run()
        try night.add(selected(), run: second)
        try night.add(authored(), run: second)

        let flag = try #require(try night.read().health?.first)
        #expect(flag.cause == .authoringInvariantBroken)
        #expect(flag.recoveredAt == nil)
        #expect(flag.fixLink == .inspector(.card("card-1")))
    }

    @Test("An over-budget reason that does not parse degrades to the cause and still links to Settings")
    func unparsedOverBudgetDegrades() throws {
        let fixture = RecoveryFixture()
        var night = try Night(fixture.open())
        try night.add(
            .featureAuthoringFailed(name: featureName, groupKey: "g", reason: "over the description budget of 10"),
            run: 0
        )

        let flag = try #require(try night.read().health?.first)
        #expect(flag.detail == "author: authoring \"\(featureName)\" faulted: over the description budget")
        #expect(flag.fixLink == .linearWorkspaces)
    }

    @Test("verdictLine says how many failed runs recovered when one of two did")
    func recoveredRunCount() throws {
        let fixture = RecoveryFixture()
        var night = try Night(fixture.open())
        try night.add(.actIncomplete(reason: scopeReason), run: 0)
        let second = night.run()
        try night.add(selected(), run: second)
        try night.add(.featureBreakdownRejected(name: featureName, reason: overBudget), run: second)

        let pulse = try night.read()
        #expect(pulse.night?.verdictLine == "2 Act runs failed, 1 recovered — see Health")
        #expect(pulse.night?.firstFailureHeadline == "The author Act did no work: the board scope is unresolved")
    }
}

@Suite("The Night's account words route rejections and invariant breaks")
struct RouteRejectionAccountTests {
    private func entry(_ id: Int64, _ event: JournalEvent) -> NightAccount.Entry {
        NightAccount.Entry(
            record: JournalEventRecord(id: id, event: event, act: .author, runID: nil, nightID: 1, occurredAt: epoch),
            cardNames: [:]
        )
    }

    @Test("A Route rejection is worded with its Route, cause and one-line reason, and is not a problem")
    func rejectionWording() {
        let reason = "Work Card \"T\" (backend) composes 12,153 UTF-16 code units, over the description budget of "
            + "10,000: Brief 7,000"
        let rejection = entry(1, .authoringRouteRejected(
            pass: .breakdown, route: "claude/fable/high", ordinal: 2, cause: .overDescriptionBudget, reason: reason
        ))
        #expect(!rejection.isProblem)
        #expect(rejection.headline == "claude/fable/high: over the description budget — "
            + "Work Card \"T\" (backend) is 12,153 of 10,000 description budget")
        #expect(rejection.detail == "breakdown pass, Route 2 of the walk")
    }

    @Test("The next problem lands on the folded rejection, not on a Route row")
    func timelineSkipsRouteRows() {
        let rejection = entry(1, .authoringRouteRejected(
            pass: .breakdown, route: "a/b/c", ordinal: 1, cause: .invalidOutput, reason: "bad"
        ))
        let fault = entry(2, .featureBreakdownRejected(name: featureName, reason: "bad"))
        let run = NightAccount.ActRun(
            id: "r", act: "author", startedAt: epoch, outcome: .ended, entries: [rejection, fault]
        )
        let timeline = NightTimeline(account: NightTimelineFixture.night([run]))
        #expect(timeline.items.filter(\.entry.isProblem).map(\.entry.id) == [2])
    }

    @Test("An authoring invariant break is worded")
    func invariantWording() {
        let broken = entry(3, .authoringInvariantBroken(cardID: 1, issueID: "c", reason: "dangling"))
        #expect(broken.headline == "A Work Card broke an authoring invariant")
        #expect(broken.detail == "dangling")
        #expect(broken.isProblem)
    }
}
