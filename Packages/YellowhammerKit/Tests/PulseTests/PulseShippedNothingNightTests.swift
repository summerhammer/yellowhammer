import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// Replays the Night of 2026-10-31 (summerhammer/yellowhammer#728) through `PulseSnapshot.read` on a real
// temporary Journal: one Card, six Attempts, a Night that shipped nothing, and a Pulse that said "verdict unknown".

private struct ShippedNothingFixture: ~Copyable {
    let directory = FileManager.default.temporaryDirectory.appending(component: "yh-pulse-nothing-\(UUID())")
    let projectID = ProjectID(rawValue: "nothing")! // swiftlint:disable:this force_unwrapping

    deinit { try? FileManager.default.removeItem(at: directory) }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private func makeRoute(_ cli: String, _ model: String, _ effort: String) -> Route {
    guard let route = Route(cli: cli, model: model, effort: effort) else { preconditionFailure("empty Route part") }
    return route
}

private let claudeFable = makeRoute("claude", "fable", "high")
private let claudeSonnet = makeRoute("claude", "sonnet", "medium")
private let codex = makeRoute("codex", "gpt-6.1-sol", "high")

private func at(_ seconds: Int) -> Date { epoch.addingTimeInterval(TimeInterval(seconds)) }

/// One Night's Journal: the Act's run, the Night, and a Feature with Cards inserted by the test.
private struct SeededNight {
    let journal: JournalStore
    let run: RunID
    let nightID: Int64
    let cycleID: Int64
    var clock = 0

    init(_ journal: JournalStore, mode: NightMode = .real) throws {
        self.journal = journal
        run = RunID()
        _ = try journal.claimActLease(act: .build, runID: run, mode: mode, now: at(0))
        nightID = try journal.openNight(
            nightStart: nightStart, mode: mode, act: .build, runID: run, now: at(0)
        ).night.id
        cycleID = try insertFeature(journal, issueID: "YLH-400").cycleID
    }

    /// One Attempt on the Card that ends as `ending`, with the Check it ran, when any.
    mutating func attempt(
        _ cardID: Int64, _ route: Route, _ ending: AttemptEnding, check: CheckRunResult? = nil
    ) throws {
        clock += 30
        let started = try journal.recordAttempt(
            cardID: cardID, route: route, runID: run, act: .build, nightID: nightID, now: at(clock)
        )
        if let check {
            try journal.append(
                .checkRan(CheckRanPayload(
                    cardID: cardID, issueID: try journal.card(id: cardID).issueID, attemptID: started.id,
                    result: check, exitStatus: check == .failed ? 1 : 0, output: nil, judgedCommit: nil
                )),
                act: .build, runID: run, nightID: nightID, now: at(clock + 10)
            )
        }
        clock += 30
        _ = try journal.endAttempt(
            attemptID: started.id, ending: ending, runID: run, act: .build, nightID: nightID, now: at(clock)
        )
    }

    mutating func usageLimit(_ route: Route) throws {
        clock += 5
        try journal.recordUsageLimit(
            route: route, resetHint: nil, runID: run, act: .build, nightID: nightID, now: at(clock)
        )
    }

    mutating func append(_ event: JournalEvent) throws {
        clock += 5
        try journal.append(event, act: .build, runID: run, nightID: nightID, now: at(clock))
    }

    mutating func close() throws {
        clock += 30
        try journal.closeNight(id: nightID, reason: .nightEnd, act: .land, runID: run, now: at(clock))
    }
}

private func projectSnapshot(_ fixture: borrowing ShippedNothingFixture, _ pulse: PulseSnapshot) -> ProjectSnapshot {
    ProjectSnapshot(id: fixture.projectID, name: "nothing", repos: [], pulse: pulse)
}

@Test("The 2026-10-31 Night: one Card, six Attempts, nothing shipped, reads as a failed Night")
func replayOfTheNightThatShippedNothing() throws {
    let fixture = ShippedNothingFixture()
    let journal = try fixture.open()
    var night = try SeededNight(journal)
    let card = try insertCard(journal, cycleID: night.cycleID, issueID: "YLH-406", state: .todo)

    try night.attempt(card, claudeFable, .roundsExhausted(rounds: 3), check: .failed)
    try night.usageLimit(codex)
    try night.attempt(card, codex, .usageLimited())
    try night.usageLimit(codex)
    try night.attempt(card, claudeSonnet, .roundsExhausted(rounds: 3), check: .failed)
    try night.usageLimit(claudeFable)
    try night.attempt(card, codex, .usageLimited())
    try night.usageLimit(codex)
    try night.attempt(card, codex, .usageLimited())
    try night.usageLimit(codex)
    try night.attempt(card, codex, .usageLimited())
    try night.usageLimit(codex)
    try night.close()

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: at(night.clock + 60))
    let nightPulse = try #require(pulse.night)
    #expect(nightPulse.state == .done)
    #expect(nightPulse.mode == .real)
    #expect(nightPulse.endedWithoutShipping)

    let verdict = try #require(nightPulse.verdictLine)
    #expect(verdict.contains("Nothing shipped — 1 Card worked, no Cycle landed"))
    #expect(verdict.contains("2 Attempts rounds-exhausted (YLH-406)"))
    #expect(verdict.contains("codex usage limit, 5 times — until"))
    #expect(verdict.contains("claude usage limit, 1 time — until"))

    let excluded = (pulse.health ?? []).filter { $0.kind == .routeExcluded }
    #expect(excluded.map(\.detail).sorted() == [
        "claude/fable/high — rounds-exhausted on YLH-406", "claude/sonnet/medium — rounds-exhausted on YLH-406"
    ])
    #expect(excluded.allSatisfy { $0.occurrenceCount == 1 })
    let usage = try #require((pulse.health ?? []).first { $0.kind == .usageLimited })
    #expect(usage.detail.hasPrefix("codex — 5 times, until "))
    guard case .nightAccount(let accountID, _)? = usage.fixLink else {
        Issue.record("usage limit flag has no Night account link")
        return
    }
    #expect(accountID == night.nightID)

    #expect(nightPulse.problemHeadline == "Night ended without shipping: YLH-406: 2 Attempts rounds-exhausted")
    #expect(projectSnapshot(fixture, pulse).failureMark == nightPulse.problemHeadline)

    let feature = try #require(pulse.feature)
    #expect(feature.stallNote
        == "Stalled — the last Attempt on every remaining Card failed or hit a usage limit (YLH-406)")
}

@Test("A Night that shipped a pull request with no failures reads as before, with no problem headline")
func shippedNightIsNotAProblem() throws {
    let fixture = ShippedNothingFixture()
    let journal = try fixture.open()
    var night = try SeededNight(journal)
    let first = try insertCard(journal, cycleID: night.cycleID, issueID: "YLH-410", state: .todo, order: 1)
    let second = try insertCard(journal, cycleID: night.cycleID, issueID: "YLH-411", state: .todo, order: 2)
    try night.attempt(first, claudeFable, .success, check: .passed)
    try night.attempt(second, claudeFable, .success, check: .passed)
    try night.append(.cardStateTransitioned(
        cardID: first, issueID: "YLH-410", from: .inProgress, to: .done, waitingReason: nil, blockReason: nil
    ))
    try night.append(.landStep(step: .openPullRequest, repository: "main", outcome: .completed, detail: nil))
    try night.append(.cycleLanded(cycleID: night.cycleID))
    try night.close()

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: at(night.clock + 60))
    let nightPulse = try #require(pulse.night)
    #expect(!nightPulse.endedWithoutShipping)
    #expect(nightPulse.problemHeadline == nil)
    #expect(pulse.health == nil)
    #expect(projectSnapshot(fixture, pulse).failureMark == nil)
    // No fact applies, so the fallback says how much ran: a Night with Attempt events is never "verdict unknown".
    #expect(nightPulse.verdictLine == "2 Attempts ended on 2 Cards")
}

@Test("An open rehearsal Night with worked Cards says it is a rehearsal and never ended without shipping")
func rehearsalNightShipsNothingByDefinition() throws {
    let fixture = ShippedNothingFixture()
    let journal = try fixture.open()
    var night = try SeededNight(journal, mode: .rehearsal)
    let card = try insertCard(journal, cycleID: night.cycleID, issueID: "YLH-406", state: .todo)
    try night.attempt(card, claudeFable, .roundsExhausted(rounds: 3), check: .failed)

    let pulse = try PulseSnapshot.read(from: journal, status: .working, asOf: at(night.clock + 60))
    let nightPulse = try #require(pulse.night)
    #expect(nightPulse.mode == .rehearsal)
    #expect(nightPulse.state == .running)
    #expect(!nightPulse.endedWithoutShipping)
    #expect(try #require(nightPulse.verdictLine).contains("Rehearsal Night — nothing ships in a rehearsal"))
    #expect(try #require(nightPulse.verdictLine).contains("1 Attempt rounds-exhausted (YLH-406)"))
    #expect(try !#require(nightPulse.verdictLine).contains("Nothing shipped"))
}

@Test("A Card that went green after a failed Attempt leaves no Night-level notice")
func recoveredCardLeavesNoNotice() throws {
    let fixture = ShippedNothingFixture()
    let journal = try fixture.open()
    var night = try SeededNight(journal)
    let card = try insertCard(journal, cycleID: night.cycleID, issueID: "YLH-406", state: .todo)
    try night.attempt(card, claudeFable, .roundsExhausted(rounds: 3), check: .failed)
    try night.attempt(card, claudeSonnet, .success, check: .passed)
    try night.append(.cardStateTransitioned(
        cardID: card, issueID: "YLH-406", from: .inProgress, to: .done, waitingReason: nil, blockReason: nil
    ))
    try night.close()

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: at(night.clock + 60))
    let nightPulse = try #require(pulse.night)
    #expect(nightPulse.problemHeadline == nil)
    #expect(pulse.health == nil)
    #expect(nightPulse.verdictLine == "2 Attempts ended on 1 Card")
}

@Test("No stall note while an Attempt runs, or while a remaining Card has no Attempt yet")
func stallNoteNeedsEveryRemainingCardToHaveFailed() throws {
    let fixture = ShippedNothingFixture()
    let journal = try fixture.open()
    var night = try SeededNight(journal)
    let failed = try insertCard(journal, cycleID: night.cycleID, issueID: "YLH-406", state: .todo, order: 1)
    let fresh = try insertCard(journal, cycleID: night.cycleID, issueID: "YLH-407", state: .todo, order: 2)
    try night.attempt(failed, claudeFable, .hardFailure(.exitStatus(1)))

    let untried = try PulseSnapshot.read(from: journal, status: .idle, asOf: at(night.clock + 60))
    #expect(try #require(untried.feature).stallNote == nil)

    try night.attempt(fresh, claudeFable, .roundsExhausted(rounds: 3))
    let stalled = try PulseSnapshot.read(from: journal, status: .idle, asOf: at(night.clock + 60))
    #expect(try #require(stalled.feature).stallNote?.hasSuffix("(YLH-406, YLH-407)") == true)

    _ = try journal.recordAttempt(
        cardID: fresh, route: claudeSonnet, runID: night.run, act: .build, nightID: night.nightID,
        now: at(night.clock + 30)
    )
    let running = try PulseSnapshot.read(from: journal, status: .idle, asOf: at(night.clock + 60))
    #expect(try #require(running.feature).stallNote == nil)
}
