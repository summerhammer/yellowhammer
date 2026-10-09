import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// The Journal the UI test bundle renders a populated Pulse from (issue #231). The bundle links no
// Journal module and its sandboxed runner cannot exec a binary it wrote, so it cannot build a Journal
// at test time: the writer below builds one here, and the file is committed as a resource of the UI
// test target. `PulseJournalUITests` copies it to `journals/archive.db` in its fixture configuration
// directory, whose `archive` Project declares one Repo, `archive`.
//
// Regenerate the file after a schema change (a bump of `journal-schema-N`) or a change to the seed:
//
//     YH_WRITE_UI_TEST_JOURNAL=1 swift test --package-path Packages/YellowhammerKit \
//         --filter writeUITestJournal

private let uiTestJournalProject = ProjectID(rawValue: "archive")!  // swiftlint:disable:this force_unwrapping
private let uiTestJournalRepo = "archive"

/// 2026-09-21T20:00:00Z. In the past, so the app's Now group, which reads as of the wall clock, shows
/// a running Attempt's elapsed time as positive.
private let seededAt = Date(timeIntervalSince1970: 1_790_020_800)

/// `YellowhammerUITests/Fixtures/archive.db`, found from this file's place in the repository.
private let committedUITestJournal = URL(filePath: #filePath)
    .deletingLastPathComponent()  // PulseTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // YellowhammerKit
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()  // the repository
    .appending(components: "YellowhammerUITests", "Fixtures", "archive.db", directoryHint: .notDirectory)

private let regenerate = """
    Regenerate it: YH_WRITE_UI_TEST_JOURNAL=1 swift test --package-path Packages/YellowhammerKit \
    --filter writeUITestJournal
    """

/// A seeded Linear issue: the Journal's `issue_id` is Linear's issue UUID, and `ARC-n` is the identifier
/// a person reads, recorded beside it as the Delta Read would.
private func issueID(_ number: Int) -> String {
    "00000000-0000-4000-8000-0000000000\(number)"
}

private struct SeededCard {
    let number: Int
    let title: String
    let state: CardState
    var blockReason: BlockReason?
}

/// The seed. `PulseJournalUITests` names these issue ids, identifiers, the running Attempt's id (`2`)
/// and the pull request number, so a change here is a change there.
///
/// - Feature `ARC-10`, in flight, with one Repo Lane, `archive`, and pull request #42 on it.
/// - `ARC-11` Blocked (route failure), with one ended Attempt and a failed Check.
/// - `ARC-12` Waiting on You.
/// - `ARC-13` In Progress, with an open Attempt: the one running Attempt.
/// - `ARC-14` Done.
/// - A Night, opened and still running, with Night Card `ARC-20`. No Act Lease is left held.
///
/// Every issue's identifier and Linear URL is recorded. Every write falls within one Act Lease's ten
/// minutes of `seededAt`.
private func seedUITestJournal(_ journal: JournalStore) throws {
    let run = RunID()
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: seededAt)
    let night = try journal.openNight(
        nightStart: try #require(NightStart(rawValue: "2026-09-21")), mode: .real, act: .build, runID: run,
        now: seededAt
    ).night
    _ = try journal.recordNightCard(id: night.id, issueID: issueID(20), act: .build, runID: run, now: seededAt)
    let feature = try insertFeature(journal, issueID: issueID(10))
    let cards = [
        SeededCard(number: 11, title: "Migrate the archive index", state: .blocked, blockReason: .routeFailure),
        SeededCard(number: 12, title: "Choose the retention window", state: .waitingOnYou),
        SeededCard(number: 13, title: "Backfill archived Cards", state: .inProgress),
        SeededCard(number: 14, title: "Add the archive schema", state: .done)
    ]
    var cardIDs: [Int: Int64] = [:]
    for (order, card) in cards.enumerated() {
        let id = try insertCard(
            journal, cycleID: feature.cycleID, issueID: issueID(card.number), repository: uiTestJournalRepo,
            state: card.state, blockReason: card.blockReason, order: order + 1
        )
        try journal.updateCardTitle(cardID: id, title: card.title, runID: run, now: seededAt)
        cardIDs[card.number] = id
    }
    for number in [10, 11, 12, 13, 14, 20] {
        try journal.recordIssueLink(
            issueID: issueID(number), key: "ARC-\(number)", url: "https://linear.app/acme/issue/ARC-\(number)",
            runID: run, now: seededAt
        )
    }

    try seedAttempts(
        journal, blocked: try #require(cardIDs[11]), running: try #require(cardIDs[13]), nightID: night.id,
        runID: run
    )
    try journal.recordPullRequest(
        featureID: feature.featureID, repository: uiTestJournalRepo,
        url: "https://github.com/acme/archive/pull/42", nightID: night.id, runID: run, now: seededAt
    )
    _ = try journal.acceptOutbox(
        [OutboxDraft(clientID: UUID(), operation: "comment", payload: "{}")],
        runID: run, now: seededAt
    )
    _ = try journal.releaseActLease(runID: run)
}

/// `blocked` gets one ended Attempt with a failed Check; `running` gets the one open Attempt.
private func seedAttempts(
    _ journal: JournalStore, blocked: Int64, running: Int64, nightID: Int64, runID: RunID
) throws {
    let failed = try journal.recordAttempt(
        cardID: blocked, route: route(), routeSource: "entry", runID: runID, nightID: nightID, now: seededAt
    )
    try journal.append(
        .checkRan(
            cardID: blocked, issueID: issueID(11), attemptID: failed.id, result: .failed,
            exitStatus: 1, output: "swift test: 3 failures", judgedCommit: nil
        ),
        runID: runID, nightID: nightID, now: seededAt.addingTimeInterval(240)
    )
    _ = try journal.endAttempt(
        attemptID: failed.id, result: "hardFailure", classification: "capability", consumedHow: "route failed",
        runID: runID, now: seededAt.addingTimeInterval(270)
    )
    _ = try journal.recordAttempt(
        cardID: running, route: route(), routeSource: "entry", runID: runID, nightID: nightID,
        now: seededAt.addingTimeInterval(300)
    )
}

/// A throwaway directory, removed on deinit, so a test creates it in its own body.
private struct ScratchDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(component: "yh-ui-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// A freshly seeded Journal at the current schema, closed when this returns.
    func seededJournal() throws -> URL {
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: url, id: uiTestJournalProject)
        do {
            let journal = try JournalStore.open(configurationDirectory: url, projectID: uiTestJournalProject)
            try seedUITestJournal(journal)
        }
        return fileURL
    }
}

@Test(
    "Writes the UI test bundle's Journal fixture",
    .enabled(if: ProcessInfo.processInfo.environment["YH_WRITE_UI_TEST_JOURNAL"] != nil)
)
func writeUITestJournal() throws {
    let scratch = try ScratchDirectory()
    let seeded = try scratch.seededJournal()
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        at: committedUITestJournal.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    if fileManager.fileExists(atPath: committedUITestJournal.path) {
        try fileManager.removeItem(at: committedUITestJournal)
    }
    try fileManager.copyItem(at: seeded, to: committedUITestJournal)
}

@Test("The UI test bundle's Journal fixture is at this build's schema, so the app can open it")
func uiTestJournalIsAtCurrentSchema() throws {
    let scratch = try ScratchDirectory()
    // A copy, so the read never touches the committed file.
    let copy = scratch.url.appending(component: "archive.db", directoryHint: .notDirectory)
    try FileManager.default.copyItem(at: committedUITestJournal, to: copy)

    let journal: JournalStore
    do {
        journal = try JournalStore.openReadOnly(at: copy, projectID: uiTestJournalProject)
    } catch {
        Issue.record("The app refuses the committed fixture: \(error). \(regenerate)")
        return
    }

    #expect(
        try journal.appliedMigrations() == JournalStore.migrationIdentifiers,
        "The committed fixture's migrations differ from this build's. \(regenerate)"
    )
}

@Test("The UI fixture seed holds the current Pulse data, so UI test identifiers match it")
func uiTestJournalHoldsCurrentSeed() throws {
    let scratch = try ScratchDirectory()
    let copy = scratch.url.appending(component: "archive.db", directoryHint: .notDirectory)
    try FileManager.default.copyItem(at: committedUITestJournal, to: copy)
    // The status comes from the Project's `launchd` Act jobs, not the Journal; under a UI test's
    // fixture configuration the app reads none alive.
    let committed = try PulseSnapshot.read(
        from: try JournalStore.openReadOnly(at: copy, projectID: uiTestJournalProject), status: .idle
    )

    let fresh = try PulseSnapshot.read(
        from: try JournalStore.openReadOnly(at: try scratch.seededJournal(), projectID: uiTestJournalProject),
        status: .idle
    )

    #expect(committed == fresh, "The committed fixture is not the current seed. \(regenerate)")
    // The seed must reach every group the UI tests check.
    #expect(fresh.needsYou.cards.map(\.id) == [issueID(11), issueID(12)])
    #expect(fresh.needsYou.cards.map(\.link?.identifier) == ["ARC-11", "ARC-12"])
    #expect(fresh.now.attempts.map(\.cardID) == [issueID(13)])
    #expect(fresh.now.attempts.map(\.id) == ["2"])
    #expect(fresh.feature?.id == issueID(10))
    #expect(fresh.feature?.link?.identifier == "ARC-10")
    #expect(fresh.feature?.lanes.map(\.repo) == [uiTestJournalRepo])
    #expect(fresh.feature?.lanes.first?.pullRequest?.number == 42)
    #expect(fresh.night?.state == .running)
    #expect(fresh.night?.nightCard?.identifier == "ARC-20")
}
