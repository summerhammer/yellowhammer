import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// Replays the seshes Night of 2026-10-16 (summerhammer/yellowhammer#533): an author Act that faulted over
// the description budget must read as a failure in Health and Tonight, and the earlier board-scope failure
// it got past must read as recovered (morning-report/disclose-a-failure#recovered, #one-account).

private struct SeshesFixture: ~Copyable {
    let directory = FileManager.default.temporaryDirectory.appending(component: "yh-pulse-seshes-\(UUID())")
    let projectID = ProjectID(rawValue: "seshes")! // swiftlint:disable:this force_unwrapping

    deinit { try? FileManager.default.removeItem(at: directory) }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let feature = "Serve pending Proposals in the backend schedule read"
private let workCard = "Serve pending Proposals from the schedule endpoint"
private let rejection = "Work Card \"\(workCard)\" (seshes-backend) composes 12,153 UTF-16 code units, over the "
    + "description budget of 10,000: Transcription references 6,912; Brief 3,870; Definition of Done 1,371"
private let earlierRejection = "Work Card \"\(workCard)\" (seshes-backend) composes 11,987 UTF-16 code units, "
    + "over the description budget of 10,000: Transcription references 6,912; Brief 3,704; Definition of Done 1,371"
private let foldedReason = "the Routing Table has no Route left for the authoring Kind; last failure: breakdown on "
    + "codex/gpt-6.1-sol/high returned invalid output: \(rejection)"
private let boardScopeReason = "The Project's board scope is unresolved, so this Act did no work. Run "
    + "`yh doctor --fix --check linear`, or create the item in Linear (`yh doctor` lists what is missing): "
    + "create the `authoring defect` label in the `Block Reason` group"

private func at(_ hours: Int, _ minutes: Int, _ seconds: Int = 0) -> Date {
    epoch.addingTimeInterval(TimeInterval(hours * 3600 + minutes * 60 + seconds))
}

private func selection() -> JournalEvent {
    .featureSelected(FeatureSelectedPayload(
        name: feature, reasoning: "next in the spec", precededBy: nil, followedBy: nil, seam: nil,
        repositories: ["seshes-backend"], adoptedCardIssueIDs: [], unadoptedCardIssueIDs: []
    ))
}

/// Night 2 up to 15:10: the 14:00 author run fails on the board scope, the 14:28 author run gets past it and
/// faults over the description budget on both authoring Routes, then build and land idle.
private func seedFaultedNight(_ journal: JournalStore) throws -> Int64 {
    let runA = RunID()
    _ = try journal.claimActLease(act: .author, runID: runA, mode: .real, now: at(0, 0, 8))
    let nightID = try journal.openNight(
        nightStart: nightStart, mode: .real, act: .author, runID: runA, now: at(0, 0, 8)
    ).night.id
    try journal.recordOpeningReadyState(nightID: nightID, state: .zero)
    func append(_ event: JournalEvent, _ act: Act, _ run: RunID, _ time: Date) throws {
        try journal.append(event, act: act, runID: run, nightID: nightID, now: time)
    }
    try append(.actStarted, .author, runA, at(0, 0, 8))
    try append(.linearReached, .author, runA, at(0, 0, 9))
    try append(.actIncomplete(reason: boardScopeReason), .author, runA, at(0, 0, 10))

    let runB = RunID()
    try append(.actStarted, .author, runB, at(0, 28))
    try append(.linearReached, .author, runB, at(0, 28, 1))
    try append(selection(), .author, runB, at(0, 34))
    try append(.authoringDispatched(pass: .breakdown, route: "claude/fable/high", ordinal: 1, fixture: nil),
               .author, runB, at(0, 34, 30))
    try append(.authoringRouteRejected(
        pass: .breakdown, route: "claude/fable/high", ordinal: 1, cause: .overDescriptionBudget,
        reason: earlierRejection
    ), .author, runB, at(0, 47, 24))
    try append(.authoringDispatched(pass: .breakdown, route: "codex/gpt-6.1-sol/high", ordinal: 2, fixture: nil),
               .author, runB, at(0, 53, 18))
    try append(.authoringRouteRejected(
        pass: .breakdown, route: "codex/gpt-6.1-sol/high", ordinal: 2, cause: .overDescriptionBudget,
        reason: rejection
    ), .author, runB, at(0, 53, 19))
    try append(.featureBreakdownRejected(name: feature, reason: foldedReason), .author, runB, at(0, 53, 20))
    try append(.actEnded, .author, runB, at(0, 53, 21))

    for (act, minute) in [(Act.build, 60), (Act.land, 70)] {
        let run = RunID()
        try append(.actStarted, act, run, at(0, minute))
        try append(.linearReached, act, run, at(0, minute, 1))
        try append(.actIdle(reason: .noFeatureInFlight), act, run, at(0, minute, 2))
        try append(.actEnded, act, run, at(0, minute, 3))
    }
    return nightID
}

@Test("The seshes Night of 2026-10-16 reads as 2 failed, 1 recovered, with the authoring fault standing")
func seshesFaultedNightReadsAsFailed() throws {
    let fixture = SeshesFixture()
    let journal = try fixture.open()
    _ = try seedFaultedNight(journal)

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: at(1, 11))
    let flags = try #require(pulse.health)
    let boardScope = try #require(flags.first { $0.cause == .boardScopeUnresolved })
    let overBudget = try #require(flags.first { $0.cause == .overDescriptionBudget })

    // Recovered by the 14:28 run's first event past the board preflight (here its selection at 14:34).
    #expect(boardScope.recoveredAt.map { $0 >= at(0, 28) && $0 <= at(0, 34) } == true)
    #expect(!boardScope.canRepairBoard)
    #expect(overBudget.detail == "author: authoring \"\(feature)\" faulted: Work Card \"\(workCard)\" "
        + "(seshes-backend) is 12,153 of 10,000 description budget")
    #expect(overBudget.recoveredAt == nil)
    #expect(overBudget.lastOccurredAt == at(0, 53, 20))
    #expect(overBudget.fixLink == .linearWorkspaces)
    #expect(overBudget.nextAction?.contains("Shorten or split") == true)

    let night = try #require(pulse.night)
    #expect(night.verdictLine == "2 Act runs failed, 1 recovered — see Health")
    #expect(!night.cardsAbsence.contains("No Cards touched"))
    #expect(!night.cardsAbsence.contains("no eligible Cards at opening"))
    #expect(night.firstFailureHeadline?.contains("board scope") == true)
}

@Test("The seshes Night's 16:00 author run recovers the authoring fault: 2 failed, 2 recovered")
func seshesAuthoredRunRecoversTheFault() throws {
    let fixture = SeshesFixture()
    let journal = try fixture.open()
    let nightID = try seedFaultedNight(journal)
    let runE = RunID()
    try journal.append(.actStarted, act: .author, runID: runE, nightID: nightID, now: at(2, 0))
    try journal.append(.linearReached, act: .author, runID: runE, nightID: nightID, now: at(2, 0, 1))
    try journal.append(selection(), act: .author, runID: runE, nightID: nightID, now: at(2, 0, 10))
    try journal.append(.featureAuthored(FeatureAuthoredPayload(
        name: feature, groupKey: "walk:\(feature):\(runE.rawValue)", featureIssueID: UUID().uuidString,
        cycleID: 1, cardCount: 3, adoptedCount: 0
    )), act: .author, runID: runE, nightID: nightID, now: at(2, 0, 30))
    try journal.append(.actEnded, act: .author, runID: runE, nightID: nightID, now: at(2, 0, 31))

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: at(2, 1))
    let overBudget = try #require(pulse.health?.first { $0.cause == .overDescriptionBudget })
    #expect(overBudget.recoveredAt == at(2, 0, 30))
    #expect(pulse.health?.allSatisfy { $0.recoveredAt != nil } == true)
    #expect(pulse.night?.verdictLine == "2 Act runs failed, 2 recovered — see Health")
    #expect(pulse.night?.firstFailureHeadline != nil)
}
