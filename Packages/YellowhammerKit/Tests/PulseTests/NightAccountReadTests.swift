import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// The Inspector's Night account (OQ158 ruling items 14 and 16): the Journal events of one Night, grouped
// by Act run, in plain words, read read-only from the Night's own Project's Journal alone.

/// A throwaway configuration directory holding only Journals. Removed on deinit, so a test creates it in
/// its own body.
private struct JournalsFixture: ~Copyable {
    let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-night-account-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func project(_ id: String) throws -> ProjectID {
        try #require(ProjectID(rawValue: id))
    }

    func openJournal(_ id: String) throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: try project(id))
    }

    func read(_ nightID: Int64, in id: String) throws -> NightAccountRead {
        NightAccount.read(nightID: nightID, project: try project(id), configurationDirectory: directory)
    }
}

/// What a Night's seeding leaves behind: the Night's id, and the three runs' ids.
private struct SeededNight {
    let nightID: Int64
    let runs: [RunID]
}

private let outputTail = "SECRET-OUTPUT-TAIL line 42"

/// One Night with three Act runs: an author run that ended cleanly, a build run that failed a Repo Lane and
/// was incomplete, and a land run whose Check failed and which recorded no closing event. ALPHA-1 is the
/// Card the Check ran over.
private func seedThreeRuns(_ journal: JournalStore) throws -> SeededNight {
    let feature = try insertFeature(journal, issueID: "ALPHA-F")
    let card = try insertCard(journal, cycleID: feature.cycleID, issueID: "ALPHA-1", repository: "backend")
    // The Delta Read records a Card's readable identifier; the fixture's insert does not.
    try journal.write { db in
        try db.execute(sql: "UPDATE card SET issue_id_for_display = 'ALPHA-1' WHERE id = ?", arguments: [card])
    }
    let author = RunID()
    let build = RunID()
    let land = RunID()

    _ = try journal.claimActLease(act: .author, runID: author, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: author, now: epoch)
    let night = opening.night
    try journal.append(.actStarted, act: .author, runID: author, nightID: night.id, now: epoch.addingTimeInterval(1))
    try journal.append(.actEnded, act: .author, runID: author, nightID: night.id, now: epoch.addingTimeInterval(2))
    _ = try journal.releaseActLease(runID: author)

    _ = try journal.claimActLease(act: .build, runID: build, mode: .real, now: epoch.addingTimeInterval(10))
    try journal.append(.actStarted, act: .build, runID: build, nightID: night.id, now: epoch.addingTimeInterval(11))
    try journal.append(
        .repoLaneEnded(repository: "backend", cardsRun: 1, failure: "the Check failed", cardsSkipped: 0),
        act: .build, runID: build, nightID: night.id, now: epoch.addingTimeInterval(12)
    )
    try journal.append(
        .actIncomplete(reason: "the build Act's lanes failed: backend: the Check failed"),
        act: .build, runID: build, nightID: night.id, now: epoch.addingTimeInterval(13)
    )
    _ = try journal.releaseActLease(runID: build)

    _ = try journal.claimActLease(act: .land, runID: land, mode: .real, now: epoch.addingTimeInterval(20))
    try journal.append(.actStarted, act: .land, runID: land, nightID: night.id, now: epoch.addingTimeInterval(21))
    try journal.append(
        .checkRan(
            cardID: card, issueID: "ALPHA-1", attemptID: 1, result: .failed, exitStatus: 1,
            output: outputTail, judgedCommit: nil
        ),
        act: .land, runID: land, nightID: night.id, now: epoch.addingTimeInterval(22)
    )
    _ = try journal.releaseActLease(runID: land)
    return SeededNight(nightID: night.id, runs: [author, build, land])
}

private func account(_ read: NightAccountRead) throws -> NightAccount {
    guard case let .account(account) = read else {
        Issue.record("The Night was not read: \(read)")
        throw CancellationError()
    }
    return account
}

@Test("A Night's account groups its events by Act run, in the order each run began, with each run's outcome")
func nightAccountGroupsRuns() throws {
    let fixture = JournalsFixture()
    let seeded: SeededNight
    do { seeded = try seedThreeRuns(try fixture.openJournal("alpha")) }

    let night = try account(try fixture.read(seeded.nightID, in: "alpha"))

    #expect(night.id == seeded.nightID)
    #expect(night.nightStart == "2026-09-29")
    #expect(night.mode == .real)
    #expect(night.state == .running)
    #expect(night.openedAt == epoch)
    #expect(night.completedAt == nil)
    #expect(night.closeReason == nil)
    #expect(night.runs.map(\.id) == seeded.runs.map(\.rawValue))
    #expect(night.runs.map(\.act) == ["author", "build", "land"])
    #expect(night.runs.map(\.startedAt).first == epoch)
    #expect(
        night.runs.map(\.outcome) == [
            .ended,
            .incomplete(reason: "the build Act's lanes failed: backend: the Check failed"),
            .notEnded
        ]
    )
    #expect(night.runs.map(\.hasProblem) == [false, true, true])
    #expect(night.problemCount == 3)

    let build = night.runs[1]
    #expect(build.entries.map(\.headline) == [
        "Build Act started", "Repo Lane backend failed", "Build Act could not complete"
    ])
    #expect(build.entries.map(\.isProblem) == [false, true, true])
    #expect(build.entries[1].detail == "the Check failed")
    #expect(night.runs[0].entries.map(\.id) == night.runs[0].entries.map(\.id).sorted())
}

@Test("A Check's entry carries its result and exit status, never its output")
func nightAccountCheckRanNeverCarriesOutput() throws {
    let fixture = JournalsFixture()
    let seeded: SeededNight
    do { seeded = try seedThreeRuns(try fixture.openJournal("alpha")) }

    let night = try account(try fixture.read(seeded.nightID, in: "alpha"))
    let check = try #require(night.runs[2].entries.last)

    #expect(check.headline == "ALPHA-1: Check failed")
    #expect(check.detail == "Exit status 1")
    #expect(check.isProblem)
    let words = night.runs.flatMap(\.entries).flatMap { [$0.headline, $0.detail ?? ""] }
    #expect(!words.contains { $0.contains("SECRET-OUTPUT-TAIL") })
}

@Test("A Night's account holds that Night's events only: a sibling Night's are absent")
func nightAccountExcludesOtherNights() throws {
    let fixture = JournalsFixture()
    let seeded: SeededNight
    do {
        let journal = try fixture.openJournal("alpha")
        seeded = try seedThreeRuns(journal)
        let sibling = try journal.write { db in
            try db.execute(
                sql: "INSERT INTO night (project_id, night_start, mode, state, opened_at) VALUES (?, ?, ?, ?, ?)",
                arguments: ["alpha", "2026-09-30", "real", "opened", JournalStore.timestamp(epoch)]
            )
            return db.lastInsertedRowID
        }
        try journal.append(
            .mainlineFetchFailed(repository: "web", reason: "other Night"), runID: RunID(), nightID: sibling
        )
        try journal.append(.mainlineFetchFailed(repository: "web", reason: "unstamped"), runID: RunID())
    }

    let night = try account(try fixture.read(seeded.nightID, in: "alpha"))

    #expect(night.runs.count == 3)
    #expect(!night.runs.flatMap(\.entries).contains { $0.detail == "other Night" || $0.detail == "unstamped" })
}

@Test("Events with no run id share one unstamped group with no Act, placed by its first event")
func nightAccountUnstampedGroup() throws {
    let fixture = JournalsFixture()
    let nightID: Int64
    do {
        let journal = try fixture.openJournal("alpha")
        let run = RunID()
        _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
        let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)
        nightID = opening.night.id
        try journal.append(.linearReached, nightID: nightID, now: epoch.addingTimeInterval(1))
        try journal.append(.actStarted, act: .author, runID: run, nightID: nightID, now: epoch.addingTimeInterval(2))
        try journal.append(.cycleLanded(cycleID: 1), nightID: nightID, now: epoch.addingTimeInterval(3))
    }

    let night = try account(try fixture.read(nightID, in: "alpha"))
    let unstamped = try #require(night.runs.first { $0.id == "unstamped" })

    #expect(night.runs.filter { $0.id == "unstamped" }.count == 1)
    #expect(unstamped.act == nil)
    #expect(unstamped.entries.map(\.headline).suffix(2) == ["Reached Linear", "The Cycle landed"])
    #expect(unstamped.outcome == .notEnded)
}

@Test("A closed Night reads as done, with how it closed in plain words")
func nightAccountClosedNight() throws {
    let fixture = JournalsFixture()
    let nightID: Int64
    do {
        let journal = try fixture.openJournal("alpha")
        let run = RunID()
        _ = try journal.claimActLease(act: .land, runID: run, mode: .rehearsal, now: epoch)
        let opening = try journal.openNight(
            nightStart: nightStart, mode: .rehearsal, act: .land, runID: run, now: epoch
        )
        let night = opening.night
        _ = try journal.closeNight(
            id: night.id, reason: .nightEnd, act: .land, runID: run, now: epoch.addingTimeInterval(10)
        )
        nightID = night.id
    }

    let night = try account(try fixture.read(nightID, in: "alpha"))

    #expect(night.state == .done)
    #expect(night.mode == .rehearsal)
    #expect(night.completedAt == epoch.addingTimeInterval(10))
    #expect(night.closeReason == "reached Night end")
    #expect(night.runs.flatMap(\.entries).map(\.headline).contains("Night closed"))
}

@Test("A Night the Journal does not record reads as noSuchNight")
func nightAccountNoSuchNight() throws {
    let fixture = JournalsFixture()
    do { _ = try seedThreeRuns(try fixture.openJournal("alpha")) }

    #expect(try fixture.read(404, in: "alpha") == .noSuchNight)
}

@Test("A Project with no Journal reads as journalMissing, and no Journal is created")
func nightAccountMissingJournal() throws {
    let fixture = JournalsFixture()
    let url = JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: try fixture.project("alpha"))

    #expect(try fixture.read(1, in: "alpha") == .journalMissing)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test("An unreadable Journal reads as a journalFailure in the Journal's own words")
func nightAccountUnreadableJournal() throws {
    let fixture = JournalsFixture()
    let url = JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: try fixture.project("alpha"))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a database".utf8).write(to: url)

    guard case let .journalFailure(message) = try fixture.read(1, in: "alpha") else {
        Issue.record("An unreadable Journal was not a failure")
        return
    }
    #expect(!message.isEmpty)
}

@Test("A Night's account is read from its own Project's Journal alone, though both Nights have the same id")
func nightAccountReadsItsOwnJournal() throws {
    let fixture = JournalsFixture()
    let alphaNight: Int64
    let betaNight: Int64
    do {
        let alpha = try fixture.openJournal("alpha")
        alphaNight = try seedThreeRuns(alpha).nightID

        let beta = try fixture.openJournal("beta")
        let run = RunID()
        _ = try beta.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
        let opening = try beta.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)
        betaNight = opening.night.id
        try beta.append(.authoringNoWorkAvailable, act: .author, runID: run, nightID: betaNight, now: epoch)
    }
    #expect(alphaNight == betaNight)

    let alpha = try account(try fixture.read(alphaNight, in: "alpha"))
    let beta = try account(try fixture.read(betaNight, in: "beta"))

    #expect(alpha.runs.count == 3)
    #expect(beta.runs.count == 1)
    #expect(beta.runs.flatMap(\.entries).map(\.headline).contains("Nothing to author"))
    #expect(!alpha.runs.flatMap(\.entries).map(\.headline).contains("Nothing to author"))
    #expect(!beta.runs.flatMap(\.entries).map(\.headline).contains("Repo Lane backend failed"))
}

@Test("Reading a Night's account leaves its Journal byte-for-byte unchanged and adds no sibling file")
func nightAccountReadDoesNotModifyTheJournal() throws {
    let fixture = JournalsFixture()
    let seeded: SeededNight
    do { seeded = try seedThreeRuns(try fixture.openJournal("alpha")) }
    let url = JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: try fixture.project("alpha"))
    let directory = url.deletingLastPathComponent()
    let before = try Data(contentsOf: url)
    let siblingsBefore = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))

    for _ in 0..<5 {
        _ = try fixture.read(seeded.nightID, in: "alpha")
    }

    #expect(try Data(contentsOf: url) == before)
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == siblingsBefore)
}

// MARK: - Plain words

private func entry(
    _ event: JournalEvent, act: Act? = .author, cardNames: [Int64: String] = [:]
) -> NightAccount.Entry {
    NightAccount.Entry(
        record: JournalEventRecord(
            id: 1, event: event, act: act, runID: nil, nightID: 1, occurredAt: epoch
        ),
        cardNames: cardNames
    )
}

@Test("A selected Feature is named, and its reasoning is never read")
func nightAccountFeatureSelectedNamesOnly() {
    let payload = FeatureSelectedPayload(
        name: "Pulse", reasoning: "SECRET-REASONING", precededBy: nil, followedBy: nil, seam: nil,
        repositories: ["backend"], adoptedCardIssueIDs: [], unadoptedCardIssueIDs: []
    )

    let selected = entry(.featureSelected(payload))

    #expect(selected.headline == "Selected the Feature “Pulse”")
    #expect(selected.detail == nil)
    #expect(!selected.isProblem)
    #expect(!selected.headline.contains("SECRET"))
}

@Test("An event outside the worded families reads as its type's name in plain words, acronyms intact")
func nightAccountFallbackWording() {
    let wip = entry(
        .worktreeWIPCommitted(featureID: 1, repository: "backend", wipCommit: "abc", wipRef: "ref", resetTo: nil)
    )
    let spawned = entry(
        .agentCLIProcessSpawned(cardID: 1, issueID: "A-1", attemptID: 1, pass: .worker, cli: "claude")
    )

    #expect(wip.headline == "Worktree WIP committed")
    #expect(wip.detail == nil)
    #expect(spawned.headline == "Agent CLI process spawned")
}

@Test("A Card is named by its display identifier, or by its row id when the Journal does not name it")
func nightAccountNamesCards() {
    let transition = JournalEvent.cardStateTransitioned(
        cardID: 7, issueID: "uuid", from: .inProgress, to: .blocked, waitingReason: nil, blockReason: .checkFailure
    )

    #expect(entry(transition, cardNames: [7: "YH-7"]).headline == "YH-7 moved from In Progress to Blocked")
    #expect(entry(transition, cardNames: [7: "YH-7"]).detail == "Block Reason: check failure")
    #expect(entry(transition).headline == "Card 7 moved from In Progress to Blocked")
}

@Test("A Check that passed is not a problem; one that failed is; a repo lane failure is, a clean one is not")
func nightAccountProblemEntries() {
    func check(_ result: CheckRunResult) -> JournalEvent {
        .checkRan(
            cardID: 1, issueID: "A-1", attemptID: 1, result: result, exitStatus: nil, output: nil, judgedCommit: nil
        )
    }

    #expect(!entry(check(.passed)).isProblem)
    #expect(entry(check(.failed)).isProblem)
    #expect(!entry(check(.declaredNone)).isProblem)
    #expect(entry(.repoLaneEnded(repository: "a", cardsRun: 1, failure: "x", cardsSkipped: 0)).isProblem)
    #expect(!entry(.repoLaneEnded(repository: "a", cardsRun: 1, failure: nil, cardsSkipped: 0)).isProblem)
    #expect(entry(.linearUnreachableHalted).isProblem)
    #expect(entry(.leaseReclaimed(previousRunID: RunID(), previousAct: .build, expiredAt: epoch)).isProblem)
    #expect(!entry(.linearReached).isProblem)
    #expect(!entry(.actEnded).isProblem)
}

@Test("A Feature is named by its display identifier, not its issue UUID, and the raw id is the fallback")
func nightAccountNamesFeaturesByDisplayIdentifier() throws {
    let fixture = JournalsFixture()
    let featureUUID = "6f0c2b1e-3a52-4d6a-9d1c-0a7a4b9f1e11"
    let unknownUUID = "b3d7a9e0-77c4-4f0e-8a65-2f1d9c3b5e22"
    let nightID: Int64
    do {
        let journal = try fixture.openJournal("alpha")
        _ = try insertFeature(journal, issueID: featureUUID)
        try journal.write { db in
            try db.execute(
                sql: "UPDATE feature SET issue_id_for_display = 'YLH-347' WHERE issue_id = ?",
                arguments: [featureUUID]
            )
        }
        let run = RunID()
        _ = try journal.claimActLease(act: .land, runID: run, mode: .real, now: epoch)
        let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .land, runID: run, now: epoch)
        nightID = opening.night.id
        try journal.append(
            .featureReturned(cycleID: 1, featureIssueID: featureUUID, unmet: 4, unresolved: 0),
            act: .land, runID: run, nightID: nightID, now: epoch.addingTimeInterval(1)
        )
        try journal.append(
            .authoringSkippedFeatureInFlight(featureIssueID: unknownUUID),
            act: .land, runID: run, nightID: nightID, now: epoch.addingTimeInterval(2)
        )
    }

    let entries = try account(try fixture.read(nightID, in: "alpha")).runs.flatMap(\.entries)

    let returned = try #require(entries.first { $0.headline.contains("returned to you") })
    #expect(returned.headline == "The Feature YLH-347 was returned to you")
    #expect(!returned.headline.contains(featureUUID))
    let skipped = try #require(entries.first { $0.headline.contains("already in flight") })
    #expect(skipped.detail == unknownUUID)
}

// MARK: - Runs that stood down

/// Opens a Night at `epoch + opened` and, when `closed` is given, closes it at `epoch + closed`.
private func openNight(
    _ journal: JournalStore, start: String, opened: TimeInterval, closed: TimeInterval? = nil
) throws -> Int64 {
    let run = RunID()
    let night = try #require(NightStart(rawValue: start))
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch.addingTimeInterval(opened))
    let id = try journal.openNight(
        nightStart: night, mode: .real, act: .author, runID: run, now: epoch.addingTimeInterval(opened)
    ).night.id
    if let closed {
        _ = try journal.closeNight(
            id: id, reason: .nightEnd, act: .author, runID: run, now: epoch.addingTimeInterval(closed)
        )
    }
    _ = try journal.releaseActLease(runID: run)
    return id
}

/// Records a run that stood down at `epoch + at`: no Night stamp, as the Act never joined the Night.
private func standDown(_ journal: JournalStore, at: TimeInterval, act: Act = .build) throws {
    let holder = ActLease(
        act: .author, runID: RunID(), mode: .real, claimedAt: epoch, heartbeatAt: epoch,
        expiresAt: epoch.addingTimeInterval(600)
    )
    try journal.append(.actStoodDown(holder: holder), act: act, runID: RunID(), now: epoch.addingTimeInterval(at))
}

private func standDownRuns(_ night: NightAccount) -> [NightAccount.ActRun] {
    night.runs.filter { $0.outcome == .stoodDown }
}

@Test("A run that stood down inside a closed Night's span is on its Act's lane, naming the holder")
func nightAccountIncludesStandDownInsideSpan() throws {
    let fixture = JournalsFixture()
    let nightID: Int64
    do {
        let journal = try fixture.openJournal("alpha")
        nightID = try openNight(journal, start: "2026-09-29", opened: 0, closed: 100)
        try standDown(journal, at: 50)
    }

    let night = try account(try fixture.read(nightID, in: "alpha"))
    let stoodDown = try #require(standDownRuns(night).first)

    #expect(standDownRuns(night).count == 1)
    #expect(stoodDown.act == "build")
    #expect(stoodDown.entries.count == 1)
    #expect(stoodDown.entries.first?.detail == "Held by the author Act")
}

@Test("A run that stood down before the Night opened is not in its account")
func nightAccountExcludesStandDownBeforeOpening() throws {
    let fixture = JournalsFixture()
    let nightID: Int64
    do {
        let journal = try fixture.openJournal("alpha")
        try standDown(journal, at: -10)
        nightID = try openNight(journal, start: "2026-09-29", opened: 0, closed: 100)
    }

    #expect(standDownRuns(try account(try fixture.read(nightID, in: "alpha"))).isEmpty)
}

@Test("A run that stood down after a Night closed is not in its account")
func nightAccountExcludesStandDownAfterClose() throws {
    let fixture = JournalsFixture()
    let nightID: Int64
    do {
        let journal = try fixture.openJournal("alpha")
        nightID = try openNight(journal, start: "2026-09-29", opened: 0, closed: 100)
        try standDown(journal, at: 101)
    }

    #expect(standDownRuns(try account(try fixture.read(nightID, in: "alpha"))).isEmpty)
}

@Test("A run that stood down after an open Night opened is in its account: an open Night has no end")
func nightAccountIncludesStandDownInOpenNight() throws {
    let fixture = JournalsFixture()
    let nightID: Int64
    do {
        let journal = try fixture.openJournal("alpha")
        nightID = try openNight(journal, start: "2026-09-29", opened: 0)
        try standDown(journal, at: 5_000, act: .land)
    }

    let night = try account(try fixture.read(nightID, in: "alpha"))

    #expect(night.state == .running)
    #expect(standDownRuns(night).map(\.act) == ["land"])
}

@Test("A run that stood down inside the second Night's span is in its account, not the first's")
func nightAccountAttributesStandDownToItsOwnNight() throws {
    let fixture = JournalsFixture()
    let first: Int64
    let second: Int64
    do {
        let journal = try fixture.openJournal("alpha")
        first = try openNight(journal, start: "2026-09-29", opened: 0, closed: 100)
        second = try openNight(journal, start: "2026-09-30", opened: 200)
        try standDown(journal, at: 250)
    }

    #expect(standDownRuns(try account(try fixture.read(first, in: "alpha"))).isEmpty)
    #expect(standDownRuns(try account(try fixture.read(second, in: "alpha"))).count == 1)
}

@Test("An unstamped row that is not a stand-down stays out of the account, even inside the span")
func nightAccountExcludesOtherUnstampedRows() throws {
    let fixture = JournalsFixture()
    let nightID: Int64
    do {
        let journal = try fixture.openJournal("alpha")
        nightID = try openNight(journal, start: "2026-09-29", opened: 0, closed: 100)
        try journal.append(
            .actIncomplete(reason: "unstamped failure"), act: .build, runID: RunID(),
            now: epoch.addingTimeInterval(50)
        )
    }

    let night = try account(try fixture.read(nightID, in: "alpha"))

    #expect(!night.runs.flatMap(\.entries).contains { $0.detail == "unstamped failure" })
}
