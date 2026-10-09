import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

private struct FailureFixture: ~Copyable {
    let directory = FileManager.default.temporaryDirectory.appending(component: "yh-pulse-failure-\(UUID())")
    let projectID = ProjectID(rawValue: "fixture")! // swiftlint:disable:this force_unwrapping

    deinit { try? FileManager.default.removeItem(at: directory) }

    func open(project: ProjectID? = nil) throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: project ?? projectID)
    }
}

private func openFailureNight(_ journal: JournalStore) throws -> (nightID: Int64, run: RunID) {
    let run = RunID()
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .build, runID: run, now: epoch)
    return (opening.night.id, run)
}

@Test("A later successful run of the same Act in the Night recovers its failure")
func failedActRecovery() throws {
    let fixture = FailureFixture()
    let journal = try fixture.open()
    let opening = try openFailureNight(journal)
    let failedAt = epoch
    try journal.append(.actIncomplete(reason: "Linear returned 503"), act: .build, runID: opening.run,
                       nightID: opening.nightID, now: failedAt)
    let successRun = RunID()
    let recoveredAt = failedAt.addingTimeInterval(900)
    try journal.append(.actEnded, act: .build, runID: successRun, nightID: opening.nightID, now: recoveredAt)

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: recoveredAt)
    #expect(pulse.health?.first?.recoveredAt == recoveredAt)
}

@Test("A later failed Act run with a different reason does not leave an earlier row marked recovered")
func laterFailureClearsRecovery() throws {
    let fixture = FailureFixture()
    let journal = try fixture.open()
    let opening = try openFailureNight(journal)
    try journal.append(.actIncomplete(reason: "Linear returned 503"), act: .build, runID: opening.run,
                       nightID: opening.nightID, now: epoch)
    let successRun = RunID()
    let recoveredAt = epoch.addingTimeInterval(900)
    try journal.append(.actEnded, act: .build, runID: successRun, nightID: opening.nightID, now: recoveredAt)
    let laterFailureRun = RunID()
    try journal.append(.actIncomplete(reason: "Linear returned 429"), act: .build, runID: laterFailureRun,
                       nightID: opening.nightID, now: recoveredAt.addingTimeInterval(900))

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: recoveredAt)
    #expect(pulse.health?.count == 2)
    #expect(pulse.health?.allSatisfy { $0.recoveredAt == nil } == true)
}

@Test("A successful lifecycle row sharing a failed run cannot recover that run")
func sameRunLifecycleIsNotRecovery() throws {
    let fixture = FailureFixture()
    let journal = try fixture.open()
    let opening = try openFailureNight(journal)
    try journal.append(.repoLaneEnded(repository: "main", cardsRun: 0, failure: "allocation failed"),
                       act: .build, runID: opening.run, nightID: opening.nightID, now: epoch)
    try journal.append(.actEnded, act: .build, runID: opening.run, nightID: opening.nightID,
                       now: epoch.addingTimeInterval(900))

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch.addingTimeInterval(900))
    #expect(pulse.health?.first?.recoveredAt == nil)
}

@Test("A different Act does not recover a failed run")
func differentActDoesNotRecover() throws {
    let fixture = FailureFixture()
    let journal = try fixture.open()
    let opening = try openFailureNight(journal)
    try journal.append(.actIncomplete(reason: "Linear returned 503"), act: .build, runID: opening.run,
                       nightID: opening.nightID, now: epoch)
    try journal.append(.actEnded, act: .land, runID: RunID(), nightID: opening.nightID,
                       now: epoch.addingTimeInterval(900))

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch.addingTimeInterval(900))
    #expect(pulse.health?.first?.recoveredAt == nil)
}

@Test("A successful Act in another Night does not recover a failed run")
func differentNightDoesNotRecover() throws {
    let fixture = FailureFixture()
    let journal = try fixture.open()
    let opening = try openFailureNight(journal)
    try journal.append(.actIncomplete(reason: "Linear returned 503"), act: .build, runID: opening.run,
                       nightID: opening.nightID, now: epoch)
    let otherNight = try journal.write { db -> Int64 in
        try db.execute(
            sql: "INSERT INTO night (project_id, night_start, mode, state, opened_at) VALUES (?, ?, ?, ?, ?)",
            arguments: [fixture.projectID.rawValue, "2026-09-30", "real", "closed", JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
    try journal.append(.actEnded, act: .build, runID: RunID(), nightID: otherNight,
                       now: epoch.addingTimeInterval(900))

    let flags = JournalFailures(events: try journal.events()).flags
    #expect(flags.first?.recoveredAt == nil)
}

@Test("Pulse Health aggregates pending and failed Board writes and ignores applied and aborted writes")
func undeliveredBoardWrites() throws {
    let fixture = FailureFixture()
    let journal = try fixture.open()
    try journal.write { db in
        for (index, state, error) in [
            (0, "pending", nil as String?), (1, "pending", "temporary refusal"),
            (2, "failed", "permanent refusal"), (3, "applied", nil), (4, "aborted", nil)
        ] {
            try db.execute(
                sql: """
                    INSERT INTO outbox
                        (client_id, operation, payload, created_at, state, last_error)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString.lowercased(), "comment", "{}",
                    JournalStore.timestamp(epoch.addingTimeInterval(Double(index))), state, error
                ]
            )
        }
    }

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch)
    let flag = try #require(pulse.health?.first { $0.kind == .undeliveredBoardWrites })
    #expect(pulse.health?.count == 1)
    #expect(flag.pendingWriteCount == 2)
    #expect(flag.failedWriteCount == 1)
    #expect(flag.oldestUndeliveredAt == epoch)
    #expect(flag.lastError == "permanent refusal")
}

@Test("Ten allocation failures show one Health reason and a closed Night remains done")
func repeatedAllocationFailures() throws {
    let fixture = FailureFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: "F-1")
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-1")
    let opening = try openFailureNight(journal)
    try journal.recordOpeningReadyState(nightID: opening.nightID, state: .nonzero)
    let reason = "Worktree allocation failed: branch already exists"
    for index in 0..<10 {
        let run = index == 0 ? opening.run : RunID()
        let at = epoch.addingTimeInterval(Double(index))
        try journal.append(
            .repoLaneEnded(repository: "main", cardsRun: 0, failure: reason),
            act: .build, runID: run, nightID: opening.nightID, now: at
        )
        try journal.append(
            .actIncomplete(reason: "the build Act's lanes failed: main: \(reason)"),
            act: .build, runID: run, nightID: opening.nightID, now: at
        )
    }
    _ = try journal.closeNight(
        id: opening.nightID, reason: .nightEnd, act: .build, runID: opening.run,
        now: epoch.addingTimeInterval(10)
    )
    let pulse = try PulseSnapshot.read(from: journal, status: .working, asOf: epoch.addingTimeInterval(11))
    let flags = try #require(pulse.health)
    #expect(flags.count == 1)
    #expect(flags.first?.detail == "build · main: \(reason)")
    #expect(flags.first?.occurrenceCount == 10)
    #expect(flags.first?.lastOccurredAt == epoch.addingTimeInterval(9))
    #expect(pulse.night?.state == .done)
    #expect(pulse.night?.verdictLine == "10 Act runs failed — see Health")
    #expect(pulse.night?.cardsByDisposition.isEmpty == true)
    #expect(pulse.night?.cardsAbsence.contains("eligible Cards were available") == true)
    #expect(pulse.feature?.lanes.first?.state == .idle)
    #expect(pulse.now.attempts.isEmpty)
    #expect(pulse.now.status == .idle)
}

@Test("Lane-only failures count once per run across repos; an unrelated Act reason stays visible")
func laneFailuresAndDistinctActReason() throws {
    let fixture = FailureFixture()
    let journal = try fixture.open()
    let opening = try openFailureNight(journal)
    for repo in ["app", "api"] {
        try journal.append(
            .repoLaneEnded(repository: repo, cardsRun: 0, failure: "allocation failed"),
            act: .build, runID: opening.run, nightID: opening.nightID, now: epoch
        )
    }
    var pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch)
    #expect(pulse.health?.count == 2)
    #expect(pulse.night?.state == .running)
    #expect(pulse.night?.verdictLine == "1 Act run failed — see Health")
    #expect(pulse.night?.cardsAbsence.contains("opening eligibility unknown") == true)
    try journal.append(
        .actIncomplete(reason: "Night Card publication failed after allocation failed"),
        act: .build, runID: opening.run, nightID: opening.nightID, now: epoch
    )
    pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch)
    #expect(pulse.health?.count == 3)
    #expect(pulse.night?.verdictLine == "1 Act run failed — see Health")
}

@Test("Open Attempts remain running beside a closed failed Night; stale in-progress Cards do not")
func closedFailedNightOpenAttempt() throws {
    let fixture = FailureFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: "F-1")
    let card = try insertCard(journal, cycleID: feature.cycleID, issueID: "C-1", state: .inProgress)
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-2", repository: "api", state: .inProgress)
    let opening = try openFailureNight(journal)
    _ = try journal.recordAttempt(cardID: card, route: route(), runID: opening.run, now: epoch)
    try journal.append(.actIncomplete(reason: "failure"), act: .build, runID: opening.run, nightID: opening.nightID)
    _ = try journal.closeNight(id: opening.nightID, reason: .nightEnd, act: .build, runID: opening.run, now: epoch)
    let pulse = try PulseSnapshot.read(from: journal, status: .working, asOf: epoch)
    #expect(pulse.feature?.lanes.first { $0.repo == "main" }?.state == .running)
    #expect(pulse.feature?.lanes.first { $0.repo == "api" }?.state == .idle)
    #expect(pulse.now.attempts.count == 1)
}

@Test("A live lane start is running only until its recorded end")
func liveLaneLifecycle() throws {
    let fixture = FailureFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: "F-1")
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-1")
    let opening = try openFailureNight(journal)
    try journal.append(
        .repoLaneStarted(repository: "main", cards: 1),
        act: .build, runID: opening.run, nightID: opening.nightID, now: epoch
    )
    #expect(try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch).feature?.lanes.first?.state == .running)
    try journal.append(
        .repoLaneEnded(repository: "main", cardsRun: 0, failure: "failure"),
        act: .build, runID: opening.run, nightID: opening.nightID, now: epoch
    )
    #expect(try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch).feature?.lanes.first?.state == .idle)
}

@Test("A later healthy Night clears old failures, and another Project never inherits them")
func latestNightAndProjectFailureScope() throws {
    let fixture = FailureFixture()
    let journal = try fixture.open()
    let opening = try openFailureNight(journal)
    try journal.append(
        .actIncomplete(reason: "failure"), act: .build, runID: opening.run, nightID: opening.nightID, now: epoch
    )
    #expect(try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch).health?.count == 1)
    let sibling = try fixture.open(project: #require(ProjectID(rawValue: "sibling")))
    #expect(try PulseSnapshot.read(from: sibling, status: .idle).health == nil)
    _ = try journal.openNight(
        nightStart: #require(NightStart(rawValue: "2026-09-30")), mode: .real,
        act: .build, runID: opening.run, now: epoch
    )
    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch)
    #expect(pulse.health == nil)
    #expect(pulse.night?.verdictLine == nil)
}

@Test("Quiet empty opening is qualified without a failure; unknown opening keeps the ordinary absence")
func quietNightAbsence() throws {
    let fixture = FailureFixture()
    let journal = try fixture.open()
    let opening = try openFailureNight(journal)
    #expect(try PulseSnapshot.read(from: journal, status: .idle).night?.cardsAbsence == "No Cards touched")
    try journal.recordOpeningReadyState(nightID: opening.nightID, state: .zero)
    let pulse = try PulseSnapshot.read(from: journal, status: .idle)
    #expect(pulse.health == nil)
    #expect(pulse.night?.cardsAbsence == "No Cards touched — no eligible Cards at opening")
}

@Test("Unstamped failure persists until a successful Act, without changing a prior Night's verdict")
func unstampedFailureRecovery() throws {
    let fixture = FailureFixture()
    let journal = try fixture.open()
    let failedRun = RunID()
    try journal.append(.actIncomplete(reason: "setup failed"), act: .build, runID: failedRun, now: epoch)
    let unrecovered = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch.addingTimeInterval(172800))
    #expect(unrecovered.health?.count == 1)
    try journal.append(.actEnded, act: .build, runID: RunID(), now: epoch.addingTimeInterval(1))
    #expect(try PulseSnapshot.read(from: journal, status: .idle).health == nil)
    let opening = try openFailureNight(journal)
    _ = try journal.closeNight(id: opening.nightID, reason: .nightEnd, act: .build, runID: opening.run, now: epoch)
    try journal.append(
        .actIncomplete(reason: "setup failed again"), act: .build, runID: RunID(), now: epoch.addingTimeInterval(2)
    )
    let pulse = try PulseSnapshot.read(from: journal, status: .idle)
    #expect(pulse.health?.count == 1)
    #expect(pulse.night?.state == .done)
    #expect(pulse.night?.verdictLine == nil)
}

@Test("Doctor health merges with Journal failures, and unread doctor retains them")
func mergedDoctorHealth() {
    let failure = HealthFlag(kind: .actFailure, detail: "failure", occurrenceCount: 10, lastOccurredAt: epoch)
    var pulse = PulseSnapshot(needsYou: NeedsYou(cards: []), now: Now(status: .idle, nextAct: nil, attempts: []),
                              feature: nil, night: nil, health: [failure])
    pulse.mergeDoctorHealth(nil)
    #expect(pulse.health == [failure])
    pulse.mergeDoctorHealth([])
    #expect(pulse.health == [failure])
    let doctor = HealthFlag(kind: .probeFailure, detail: "CLI missing")
    pulse.mergeDoctorHealth([doctor])
    #expect(pulse.health == [failure, doctor])
    pulse.health = nil
    pulse.mergeDoctorHealth(nil)
    #expect(pulse.health == nil)
    pulse.mergeDoctorHealth([])
    #expect(pulse.health == [])
}
