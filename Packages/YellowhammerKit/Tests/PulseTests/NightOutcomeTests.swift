import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// The pure fold of one Night's events (summerhammer/yellowhammer#728): no Journal is opened, so every fact,
// recovery rule and Health flag is asserted on hand-built events.

private let nightID: Int64 = 1
private func makeRoute(_ cli: String, _ model: String, _ effort: String) -> Route {
    guard let route = Route(cli: cli, model: model, effort: effort) else { preconditionFailure("empty Route part") }
    return route
}

private let claudeA = makeRoute("claude", "fable", "high")
private let claudeB = makeRoute("claude", "sonnet", "medium")
private let codexRoute = makeRoute("codex", "gpt-6.1-sol", "high")

private func record(_ id: Int64, _ event: JournalEvent, seconds: TimeInterval? = nil) -> JournalEventRecord {
    JournalEventRecord(
        id: id, event: event, act: .build, runID: nil, nightID: nightID,
        occurredAt: epoch.addingTimeInterval(seconds ?? TimeInterval(id * 60))
    )
}

private func ended(
    _ card: Int64, _ ending: AttemptOutcome, route: Route = claudeA, excluded: Bool = false, attempt: Int64? = nil
) -> JournalEvent {
    .attemptEnded(
        cardID: card, issueID: "issue-\(card)", attemptID: attempt ?? card * 100, route: route,
        outcome: ending.rawValue, routeExcluded: excluded
    )
}

private func check(_ card: Int64, _ result: CheckRunResult) -> JournalEvent {
    .checkRan(CheckRanPayload(
        cardID: card, issueID: "issue-\(card)", attemptID: card * 100, result: result, exitStatus: nil,
        output: nil, judgedCommit: nil
    ))
}

private func fold(_ events: [JournalEvent], names: [Int64: String] = [406: "YLH-406", 407: "YLH-407"]) -> NightOutcome {
    NightOutcome(events: events.enumerated().map { record(Int64($0.offset + 1), $0.element) }, cardNames: names)
}

private func standing(
    _ outcome: NightOutcome, mode: NightMode = .real, closed: Bool = true
) -> NightStanding {
    NightStanding(outcome: outcome, mode: mode, isClosed: closed)
}

@Test("Rounds-exhausted Attempts read per Card, counted, with the Night's first and last time")
func foldRoundsExhausted() {
    let outcome = fold([ended(406, .roundsExhausted), ended(407, .success), ended(406, .roundsExhausted)])
    #expect(outcome.cardsWorked == 2)
    #expect(outcome.attemptsEnded == 3)
    let problem = outcome.roundsExhausted.first
    #expect(problem?.cardName == "YLH-406")
    #expect(problem?.occurrence.count == 2)
    #expect(problem?.occurrence.firstEventID == 1)
    #expect(problem?.occurrence.firstAt == epoch.addingTimeInterval(60))
    #expect(problem?.occurrence.lastAt == epoch.addingTimeInterval(180))
    #expect(standing(outcome).verdictFacts.contains("2 Attempts rounds-exhausted (YLH-406)"))
    #expect(standing(outcome).firstCardProblem == "YLH-406: 2 Attempts rounds-exhausted")
}

@Test("A hard failure is a hard-failed Attempt, singular for one and plural for two Cards")
func foldHardFailures() {
    let one = fold([ended(406, .hardFailure)])
    #expect(standing(one).verdictFacts.contains("1 Attempt hard-failed (YLH-406)"))
    #expect(standing(one).firstCardProblem == "YLH-406: 1 Attempt hard-failed")
    let two = fold([ended(406, .hardFailure), ended(407, .hardFailure)])
    #expect(standing(two).verdictFacts.contains("2 Attempts hard-failed (YLH-406, YLH-407)"))
}

@Test("A Check that stayed red is a fact; one that went green after is not")
func foldRedChecks() {
    let red = fold([ended(406, .roundsExhausted), check(406, .failed), check(407, .failed), check(407, .passed)])
    #expect(red.redChecks.map(\.cardName) == ["YLH-406"])
    #expect(standing(red).verdictFacts.contains("Check stayed red on YLH-406"))
    #expect(fold([check(406, .failed), check(406, .passed)]).redChecks.isEmpty)
}

@Test("A Card whose last Attempt succeeded contributes no failure facts, flags or headline; usage limits stay")
func foldRecoveryDropsACardsFacts() {
    let until = epoch.addingTimeInterval(7_200)
    let outcome = fold([
        ended(406, .roundsExhausted, excluded: true), check(406, .failed),
        .failureCauseRecorded(cardID: 406, issueID: "issue-406", cause: "build", causeHash: "h", recurrenceCount: 3),
        ended(406, .hardFailure, route: claudeB, excluded: true),
        .routeUsageLimited(route: codexRoute.description, cli: "codex", until: until, resetHint: nil),
        ended(406, .success, route: codexRoute),
        .cardStateTransitioned(
            cardID: 406, issueID: "issue-406", from: .inProgress, to: .done, waitingReason: nil, blockReason: nil
        )
    ])
    #expect(outcome.roundsExhausted.isEmpty)
    #expect(outcome.hardFailures.isEmpty)
    #expect(outcome.redChecks.isEmpty)
    #expect(outcome.excludedRoutes.isEmpty)
    #expect(outcome.recurringCauses.isEmpty)
    #expect(outcome.usageLimits.map(\.cli) == ["codex"])
    #expect(standing(outcome).firstCardProblem == nil)
    #expect(standing(outcome).problemHeadline(nightID: nightID) == nil)
    #expect(HealthFlag.nightFlags(outcome, nightID: nightID).isEmpty)
    // The failure came last: it is not recovered.
    #expect(fold([ended(406, .success), ended(406, .roundsExhausted)]).roundsExhausted.count == 1)
}

@Test("A usage limit reads per CLI, with the latest until and hint, as a deferral and not a problem")
func foldUsageLimits() throws {
    let early = epoch.addingTimeInterval(3_600)
    let late = epoch.addingTimeInterval(7_200)
    let outcome = fold([
        .routeUsageLimited(route: codexRoute.description, cli: "codex", until: late, resetHint: "9am"),
        .routeUsageLimited(route: codexRoute.description, cli: "codex", until: early, resetHint: "8am"),
        .routeUsageLimited(route: claudeA.description, cli: "claude", until: early, resetHint: nil)
    ])
    let codex = try #require(outcome.usageLimits.first { $0.cli == "codex" })
    #expect(codex.occurrence.count == 2)
    #expect(codex.until == late)
    #expect(codex.resetHint == "8am")
    let until = late.formatted(date: .omitted, time: .shortened)
    let facts = standing(outcome).verdictFacts
    #expect(facts.contains("codex usage limit, 2 times — until \(until)"))
    #expect(facts.contains("claude usage limit, 1 time — until \(early.formatted(date: .omitted, time: .shortened))"))
    #expect(standing(outcome).problemHeadline(nightID: nightID) == nil)

    let flags = HealthFlag.nightFlags(outcome, nightID: nightID)
    #expect(flags.map(\.kind) == [.usageLimited])
    #expect(flags.first?.detail == "codex — 2 times, until \(until)")
    #expect(flags.first?.fixLink == .nightAccount(nightID, at: epoch.addingTimeInterval(60)))
}

private let deliveries: [JournalEvent] = [
    .cycleLanded(cycleID: 1),
    .landStep(step: .openPullRequest, repository: "backend", outcome: .completed, detail: nil),
    .cardStateTransitioned(
        cardID: 406, issueID: "issue-406", from: .inProgress, to: .done, waitingReason: nil, blockReason: nil
    )
]

@Test("Work is delivered by a landed Cycle, an opened pull request, or a Card reaching Done", arguments: deliveries)
func foldDeliveredWork(signal: JournalEvent) {
    let outcome = fold([ended(406, .roundsExhausted), signal])
    #expect(outcome.deliveredWork)
    #expect(!standing(outcome).endedWithoutShipping)
}

@Test("Other land steps and Card transitions do not deliver work")
func foldNonDeliveries() {
    let outcome = fold([
        ended(406, .roundsExhausted),
        .landStep(step: .push, repository: "backend", outcome: .completed, detail: nil),
        .landStep(step: .openPullRequest, repository: "backend", outcome: .failed, detail: nil),
        .cardStateTransitioned(
            cardID: 406, issueID: "issue-406", from: .todo, to: .blocked, waitingReason: nil, blockReason: nil
        )
    ])
    #expect(!outcome.deliveredWork)
    #expect(standing(outcome).endedWithoutShipping)
}

@Test("A closed real Night that worked Cards and delivered nothing ended without shipping, and says so")
func standingEndedWithoutShipping() {
    let outcome = fold([ended(406, .roundsExhausted), ended(407, .usageLimited)])
    let standing = standing(outcome)
    #expect(standing.endedWithoutShipping)
    #expect(standing.verdictFacts.first == "Nothing shipped — 2 Cards worked, no Cycle landed")
    #expect(standing.problemHeadline(nightID: nightID)
        == "Night ended without shipping: YLH-406: 1 Attempt rounds-exhausted")
    let quiet = fold([ended(407, .usageLimited)])
    #expect(NightStanding(outcome: quiet, mode: .real, isClosed: true).problemHeadline(nightID: nightID)
        == "Night ended without shipping")
    #expect(NightStanding(outcome: quiet, mode: .real, isClosed: true).verdictFacts.first
        == "Nothing shipped — 1 Card worked, no Cycle landed")
}

@Test("An open Night, a Night with no worked Card and a rehearsal Night never ended without shipping")
func standingNeverEndedWithoutShipping() {
    let worked = fold([ended(406, .roundsExhausted)])
    #expect(!standing(worked, closed: false).endedWithoutShipping)
    #expect(!standing(fold([check(406, .failed)])).endedWithoutShipping)
    let closedRehearsal = standing(worked, mode: .rehearsal)
    #expect(!closedRehearsal.endedWithoutShipping)
    #expect(closedRehearsal.verdictFacts.first == "Rehearsal Night — nothing ships in a rehearsal")
    #expect(!closedRehearsal.verdictFacts.contains { $0.hasPrefix("Nothing shipped") })
}

@Test("The fallback fact says how many Attempts ended on how many Cards, and only when Attempts ended")
func standingFallback() {
    #expect(standing(fold([ended(406, .success)])).fallbackFact == "1 Attempt ended on 1 Card")
    #expect(standing(fold([ended(406, .success), ended(407, .success), ended(407, .question)])).fallbackFact
        == "3 Attempts ended on 2 Cards")
    #expect(standing(fold([check(406, .passed)])).fallbackFact == nil)
}

@Test("A Route an unrecovered Card's Attempts excluded is one flag per Route, naming the ending and the Cards")
func flagRouteExcluded() throws {
    let outcome = fold([
        ended(406, .roundsExhausted, route: claudeA, excluded: true, attempt: 1),
        ended(407, .roundsExhausted, route: claudeA, excluded: true, attempt: 2),
        ended(406, .roundsExhausted, route: claudeB, excluded: true, attempt: 3),
        ended(406, .hardFailure, route: codexRoute, attempt: 4)
    ])
    let flags = HealthFlag.nightFlags(outcome, nightID: nightID).filter { $0.kind == .routeExcluded }
    #expect(flags.map(\.detail) == [
        "claude/fable/high — rounds-exhausted on YLH-406, YLH-407",
        "claude/sonnet/medium — rounds-exhausted on YLH-406"
    ])
    let first = try #require(flags.first)
    #expect(first.occurrenceCount == 2)
    #expect(first.lastOccurredAt == epoch.addingTimeInterval(120))
    #expect(first.fixLink == .nightAccount(nightID, at: epoch.addingTimeInterval(60)))
    #expect(first.destination == .settings)
}

@Test("A reclaimed Card that excluded its Route is the same Route's flag, counted once with its Attempt")
func flagRouteExcludedByReclaim() {
    let reclaim = JournalEvent.cardReclaimed(
        cardID: 406, issueID: "issue-406", previousRunID: RunID(), attemptID: 7, outcome: "Crashed-Unknown",
        routeExcluded: true
    )
    let events = [
        ended(406, .hardFailure, route: claudeA, excluded: true, attempt: 7), reclaim
    ].enumerated().map { record(Int64($0.offset + 1), $0.element) }
    let outcome = NightOutcome(events: events, cardNames: [406: "YLH-406"], attemptRoutes: [7: claudeA.description])
    #expect(outcome.excludedRoutes.map(\.occurrence.count) == [1])
    let alone = NightOutcome(
        events: [record(1, reclaim)], cardNames: [406: "YLH-406"], attemptRoutes: [7: claudeA.description]
    )
    #expect(alone.excludedRoutes.first?.route == claudeA.description)
    #expect(alone.excludedRoutes.first?.reason == "Crashed-Unknown")
}

@Test("Every Journal fact the Night adds is a Health flag that opens the Night's account at its first occurrence")
func flagsOpenTheNightAccount() {
    let left = { (pid: Int32, command: String) in
        JournalEvent.leftoverProcessRecorded(
            cardID: 406, issueID: "issue-406", attemptID: 1, pass: .worker, pid: pid, commandName: command,
            disposition: .leftRunningUnattributed, cwd: "/tmp"
        )
    }
    let events: [JournalEvent] = [
        ended(406, .roundsExhausted, excluded: true),
        .failureCauseRecorded(cardID: 406, issueID: "issue-406", cause: "build", causeHash: "h", recurrenceCount: 2),
        .failureCauseRecorded(cardID: 406, issueID: "issue-406", cause: "first", causeHash: "g", recurrenceCount: 1),
        .cardCommitTrailersUnread(cardID: 406, issueID: "issue-406", attemptID: 1, commit: "abc", reason: "gone"),
        .cardCommitTrailersUnread(cardID: 407, issueID: "issue-407", attemptID: 2, commit: "def", reason: "gone"),
        .sweptLeftover(.sweptByWorktreeFence), left(2, "node"), left(3, "vite"),
        .managedBlockOverBudget(issueID: "issue-406", length: 11_000, budget: 10_000),
        .expiredCardLeasesSwept(cycleID: 1, reclaimedCardIDs: [406, 407]),
        .expiredCardLeasesSwept(cycleID: 1, reclaimedCardIDs: [])
    ]
    let outcome = NightOutcome(
        events: events.enumerated().map { record(Int64($0.offset + 1), $0.element) },
        cardNames: [406: "YLH-406", 407: "YLH-407"], issueNames: ["issue-406": "YLH-406"]
    )
    let flags = HealthFlag.nightFlags(outcome, nightID: nightID)
    #expect(flags.map(\.kind) == [
        .routeExcluded, .recurringFailureCause, .commitTrailersUnread, .leftoverProcesses,
        .managedBlockOverBudget, .expiredCardLeasesSwept
    ])
    #expect(flags.map(\.detail) == [
        "claude/fable/high — rounds-exhausted on YLH-406",
        "YLH-406: build — met on 2 Nights",
        "2 commits unread on YLH-406, YLH-407",
        "2 processes left running: node, vite",
        "1 Managed Block over the description budget: YLH-406",
        "2 Cards reclaimed"
    ])
    #expect(flags.map(\.fixLink) == [
        .nightAccount(nightID, at: epoch.addingTimeInterval(60)),
        .nightAccount(nightID, at: epoch.addingTimeInterval(120)),
        .nightAccount(nightID, at: epoch.addingTimeInterval(240)),
        .nightAccount(nightID, at: epoch.addingTimeInterval(420)),
        .nightAccount(nightID, at: epoch.addingTimeInterval(540)),
        .nightAccount(nightID, at: epoch.addingTimeInterval(600))
    ])
    #expect(flags.allSatisfy { $0.destination == .settings && $0.lastOccurredAt != nil })
    #expect(standing(outcome).firstCardProblem == "YLH-406: 1 Attempt rounds-exhausted")
    #expect(standing(outcome).problemHeadline(nightID: nightID)
        == "Night ended without shipping: YLH-406: 1 Attempt rounds-exhausted")
}

@Test("Leftover processes swept by the system are not a problem")
func sweptLeftoversAreIgnored() {
    let events = [
        JournalEvent.sweptLeftover(.sweptByRunningSnapshot), .sweptLeftover(.sweptByWorktreeFence)
    ]
    let outcome = fold(events)
    #expect(outcome.unattributedLeftovers == nil)
    #expect(HealthFlag.nightFlags(outcome, nightID: nightID).isEmpty)
}

@Test("Without a Card problem the first Night flag is the headline, but a usage limit alone is not")
func headlineFallsBackToTheFirstNightFlag() {
    let trailers = JournalEvent.cardCommitTrailersUnread(
        cardID: 406, issueID: "issue-406", attemptID: 1, commit: "abc", reason: "gone"
    )
    let limit = JournalEvent.routeUsageLimited(
        route: codexRoute.description, cli: "codex", until: epoch.addingTimeInterval(9_000), resetHint: nil
    )
    let outcome = fold([limit, limit, trailers])
    #expect(standing(outcome).problemHeadline(nightID: nightID)
        == "commit trailers unread: 1 commit unread on YLH-406")
    #expect(standing(fold([limit, limit])).problemHeadline(nightID: nightID) == nil)
}

@Test("Occurrence text counts failures for Act failures and failed Attempts, times for the rest")
func occurrenceWording() {
    func text(_ kind: HealthFlagKind, _ count: Int) -> String {
        HealthFlag(kind: kind, detail: "d", occurrenceCount: count).occurrenceText
    }
    #expect(text(.actFailure, 1) == "1 failure")
    #expect(text(.routeExcluded, 2) == "2 failures")
    #expect(text(.recurringFailureCause, 3) == "3 failures")
    #expect(text(.usageLimited, 1) == "1 time")
    #expect(text(.leftoverProcesses, 4) == "4 times")
    #expect(text(.undeliveredBoardWrites, 2) == "2 times")
}

@Test("A rounds-exhausted Attempt is a problem in the Night's account, like a hard failure")
func accountTreatsRoundsExhaustedAsAProblem() {
    #expect(NightAccount.isProblem(record(1, ended(406, .roundsExhausted))))
    #expect(NightAccount.isProblem(record(2, ended(406, .hardFailure))))
    #expect(!NightAccount.isProblem(record(3, ended(406, .usageLimited))))
    #expect(!NightAccount.isProblem(record(4, ended(406, .success))))
}

private extension JournalEvent {
    static func sweptLeftover(_ disposition: LeftoverProcessDisposition) -> JournalEvent {
        .leftoverProcessRecorded(
            cardID: 406, issueID: "issue-406", attemptID: 1, pass: .worker, pid: 9, commandName: "node",
            disposition: disposition, cwd: nil
        )
    }
}
