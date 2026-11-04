import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// The Journal `PulseFailedNightUITests` renders a Night that shipped nothing from (issue #728). Like the archive
// fixture in `PulseUITestJournalTests`, it is built here, because the UI test bundle links no Journal module and its
// runner cannot exec a binary it wrote; the file is committed as a resource of the UI test target. The UI test copies
// it to `journals/owner.db` in a fixture configuration directory whose `owner` Project declares one Repo, `owner`.
//
// Regenerate the file after a schema change (a bump of `journal-schema-N`) or a change to the seed:
//
//     YH_WRITE_UI_TEST_JOURNAL=1 swift test --package-path Packages/YellowhammerKit \
//         --filter writeFailedNightUITestJournal
//
// The seed contract the UI test relies on, replaying the Night of 2026-10-31:
// - One closed real Night (`night_end`) with Night Card `OWN-20`.
// - Feature `OWN-10`, in flight, with one Repo Lane `owner` and one Card, `OWN-406`, in Todo.
// - Six Attempts on `OWN-406`: two claude Attempts `rounds-exhausted` on two different Routes, `claude/fable/high`
//   and `claude/sonnet/medium`, each excluding its Route and each with a failed Check; then four codex Attempts
//   `usage limited` on `codex/gpt-6.1-sol/high`.
// - Five `routeUsageLimited` events for codex and one for claude. No pull request, no `cycleLanded`.
// - So the Pulse reads: header "Night ended without shipping"; verdict line beginning "Nothing shipped — 1 Card
//   worked, no Cycle landed", then "2 Attempts rounds-exhausted (OWN-406)", then "codex usage limit, 5 times — until
//   HH:MM", then "claude usage limit, 1 time — until HH:MM"; exactly two `routeExcluded` Health flags and one
//   `usageLimited` flag; the Feature carries a stall note.
// - No Act Lease is held and no Outbox write is pending.
//
// The Card's Linear issue UUID ends in `40`, the Feature's in `10` and the Night Card's in `20`; the identifiers a
// person reads (`OWN-406`, `OWN-10`, `OWN-20`) are recorded beside them, as the Delta Read would.

private let failedNightProject = ProjectID(rawValue: "owner")!  // swiftlint:disable:this force_unwrapping
private let failedNightRepo = "owner"

/// 2026-09-21T20:00:00Z. In the past, so every relative time the app shows is positive.
private let seededAt = Date(timeIntervalSince1970: 1_790_020_800)

/// `YellowhammerUITests/Fixtures/failed-night.db`, found from this file's place in the repository.
private let committedFailedNightJournal = URL(filePath: #filePath)
    .deletingLastPathComponent()  // PulseTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // YellowhammerKit
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()  // the repository
    .appending(components: "YellowhammerUITests", "Fixtures", "failed-night.db", directoryHint: .notDirectory)

private let regenerate = """
    Regenerate it: YH_WRITE_UI_TEST_JOURNAL=1 swift test --package-path Packages/YellowhammerKit \
    --filter writeFailedNightUITestJournal
    """

private func issueID(_ number: Int) -> String {
    "00000000-0000-4000-8000-0000000000\(number)"
}

private func makeRoute(_ cli: String, _ model: String, _ effort: String) -> Route {
    guard let route = Route(cli: cli, model: model, effort: effort) else { preconditionFailure("empty Route part") }
    return route
}

private let claudeFable = makeRoute("claude", "fable", "high")
private let claudeSonnet = makeRoute("claude", "sonnet", "medium")
private let codex = makeRoute("codex", "gpt-6.1-sol", "high")

/// The seed, written inside one Act Lease's ten minutes of `seededAt`: every step advances the clock fifteen seconds.
private struct FailedNightSeed {
    let journal: JournalStore
    let run = RunID()
    var nightID: Int64 = 0
    var cardID: Int64 = 0
    var clock = 0

    var now: Date { seededAt.addingTimeInterval(TimeInterval(clock)) }

    init(_ journal: JournalStore) {
        self.journal = journal
    }

    mutating func step() -> Date {
        clock += 15
        return now
    }

    mutating func seed() throws {
        _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: seededAt)
        nightID = try journal.openNight(
            nightStart: try #require(NightStart(rawValue: "2026-09-21")), mode: .real, act: .build, runID: run,
            now: seededAt
        ).night.id
        _ = try journal.recordNightCard(id: nightID, issueID: issueID(20), act: .build, runID: run, now: seededAt)
        let feature = try insertFeature(journal, issueID: issueID(10))
        cardID = try insertCard(
            journal, cycleID: feature.cycleID, issueID: issueID(40), repository: failedNightRepo, state: .todo
        )
        try journal.updateCardTitle(
            cardID: cardID, title: "Revalidate the Lease before the Outbox flush", runID: run, now: seededAt
        )
        for (number, key) in [(10, "OWN-10"), (20, "OWN-20"), (40, "OWN-406")] {
            try journal.recordIssueLink(
                issueID: issueID(number), key: key, url: "https://linear.app/acme/issue/\(key)", runID: run,
                now: seededAt
            )
        }
        try attempt(claudeFable, .roundsExhausted(rounds: 3), check: true)
        try usageLimit(codex)
        try attempt(codex, .usageLimited())
        try usageLimit(codex)
        try usageLimit(claudeFable)
        try attempt(claudeSonnet, .roundsExhausted(rounds: 3), check: true)
        for _ in 0..<3 {
            try usageLimit(codex)
            try attempt(codex, .usageLimited())
        }
        try journal.closeNight(id: nightID, reason: .nightEnd, act: .land, runID: run, now: step())
        _ = try journal.releaseActLease(runID: run)
    }

    private mutating func attempt(_ route: Route, _ ending: AttemptEnding, check: Bool = false) throws {
        let started = try journal.recordAttempt(
            cardID: cardID, route: route, routeSource: "entry", runID: run, act: .build, nightID: nightID, now: step()
        )
        if check {
            try journal.append(
                .checkRan(CheckRanPayload(
                    cardID: cardID, issueID: issueID(40), attemptID: started.id, result: .failed,
                    exitStatus: 1, output: "swift test: 3 failures", judgedCommit: nil
                )),
                act: .build, runID: run, nightID: nightID, now: step()
            )
        }
        _ = try journal.endAttempt(
            attemptID: started.id, ending: ending, runID: run, act: .build, nightID: nightID, now: step()
        )
    }

    private mutating func usageLimit(_ route: Route) throws {
        try journal.recordUsageLimit(
            route: route, resetHint: nil, runID: run, act: .build, nightID: nightID, now: step()
        )
    }
}

/// A throwaway directory, removed on deinit, so a test creates it in its own body.
private struct ScratchDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(component: "yh-ui-failed-night-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// A freshly seeded Journal at the current schema, closed when this returns.
    func seededJournal() throws -> URL {
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: url, id: failedNightProject)
        do {
            let journal = try JournalStore.open(configurationDirectory: url, projectID: failedNightProject)
            var seed = FailedNightSeed(journal)
            try seed.seed()
        }
        return fileURL
    }
}

@Test(
    "Writes the UI test bundle's failed-night Journal fixture",
    .enabled(if: ProcessInfo.processInfo.environment["YH_WRITE_UI_TEST_JOURNAL"] != nil)
)
func writeFailedNightUITestJournal() throws {
    let scratch = try ScratchDirectory()
    let seeded = try scratch.seededJournal()
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        at: committedFailedNightJournal.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    if fileManager.fileExists(atPath: committedFailedNightJournal.path) {
        try fileManager.removeItem(at: committedFailedNightJournal)
    }
    try fileManager.copyItem(at: seeded, to: committedFailedNightJournal)
}

@Test("The failed-night Journal fixture is at this build's schema, so the app can open it")
func failedNightJournalIsAtCurrentSchema() throws {
    let scratch = try ScratchDirectory()
    let copy = scratch.url.appending(component: "owner.db", directoryHint: .notDirectory)
    try FileManager.default.copyItem(at: committedFailedNightJournal, to: copy)

    let journal: JournalStore
    do {
        journal = try JournalStore.openReadOnly(at: copy, projectID: failedNightProject)
    } catch {
        Issue.record("The app refuses the committed fixture: \(error). \(regenerate)")
        return
    }

    #expect(
        try journal.appliedMigrations() == JournalStore.migrationIdentifiers,
        "The committed fixture's migrations differ from this build's. \(regenerate)"
    )
}

@Test("The failed-night fixture reads as a Night that shipped nothing, so UI test identifiers match it")
func failedNightJournalHoldsCurrentSeed() throws {
    let scratch = try ScratchDirectory()
    let copy = scratch.url.appending(component: "owner.db", directoryHint: .notDirectory)
    try FileManager.default.copyItem(at: committedFailedNightJournal, to: copy)
    let committed = try PulseSnapshot.read(
        from: try JournalStore.openReadOnly(at: copy, projectID: failedNightProject), status: .idle
    )
    let fresh = try PulseSnapshot.read(
        from: try JournalStore.openReadOnly(at: try scratch.seededJournal(), projectID: failedNightProject),
        status: .idle
    )

    #expect(committed == fresh, "The committed fixture is not the current seed. \(regenerate)")
    let night = try #require(fresh.night)
    #expect(night.state == .done)
    #expect(night.mode == .real)
    #expect(night.endedWithoutShipping)
    #expect(night.nightCard?.identifier == "OWN-20")
    #expect(night.firstFailureHeadline == nil)
    #expect(night.problemHeadline == "Night ended without shipping: OWN-406: 2 Attempts rounds-exhausted")
    let verdict = try #require(night.verdictLine)
    #expect(verdict.hasPrefix(
        "Nothing shipped — 1 Card worked, no Cycle landed · 2 Attempts rounds-exhausted (OWN-406)"
    ))
    #expect(verdict.contains("codex usage limit, 5 times — until "))
    #expect(verdict.contains("claude usage limit, 1 time — until "))

    let health = try #require(fresh.health)
    let excluded = health.filter { $0.kind == .routeExcluded }
    #expect(excluded.map(\.detail) == [
        "claude/fable/high — rounds-exhausted on OWN-406", "claude/sonnet/medium — rounds-exhausted on OWN-406"
    ])
    #expect(health.filter { $0.kind == .usageLimited }.count == 1)
    #expect(health.count == 3)

    #expect(fresh.feature?.link?.identifier == "OWN-10")
    #expect(fresh.feature?.lanes.map(\.repo) == [failedNightRepo])
    #expect(fresh.feature?.lanes.first?.cards.map(\.state) == [.todo])
    #expect(fresh.feature?.stallNote?.hasSuffix("(OWN-406)") == true)
    #expect(fresh.now.attempts.isEmpty)
}
