import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// morning-report/write-the-night-summary (roadmap P12.1): the `**Standing: unmerged in-flight
// Feature:**` line — `k of N` Feature Branches merged, Nights held, and which still-unmerged Feature
// Branches carry a Mainline Conflict. Folds the old, per-Night `**Mainline Conflicts:**` section.
// Reuses `NightCardJournalFixture`, `makeBoards()` and `nightCardNightStart` from NightCardTests.swift.

private struct InFlightFixtureIDs {
    let featureID: Int64
    let cycleID: Int64
}

/// Inserts a Feature whose Cycle is open (never archived) and, when `landed` is true, landed — the
/// shape `journal.inFlightLandedFeature()` reads. `repositories` become `feature_repository` rows.
@discardableResult
private func insertInFlightFeature(
    _ journal: JournalStore, featureIssueID: String, repositories: [String], selectedNightID: Int64? = nil,
    landed: Bool = true
) throws -> InFlightFixtureIDs {
    try journal.write { db in
        let createdAt = JournalStore.timestamp(Date(timeIntervalSince1970: 1_800_000_000))
        try db.execute(
            sql: "INSERT INTO feature (issue_id, selected_night_id, state, created_at) VALUES (?, ?, ?, ?)",
            arguments: [featureIssueID, selectedNightID, "selected", createdAt]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at, landed_at) VALUES (?, ?, ?)",
            arguments: [featureID, createdAt, landed ? createdAt : nil]
        )
        let cycleID = db.lastInsertedRowID
        for repository in repositories {
            try db.execute(
                sql: "INSERT INTO feature_repository (feature_id, repository) VALUES (?, ?)",
                arguments: [featureID, repository]
            )
        }
        return InFlightFixtureIDs(featureID: featureID, cycleID: cycleID)
    }
}

/// Inserts a Night row directly, for the Nights-held arithmetic.
private func insertNightRow(
    _ journal: JournalStore, nightStart: NightStart, openedAt: Date, projectID: ProjectID
) throws {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO night (project_id, night_start, mode, state, opened_at) VALUES (?, ?, ?, ?, ?)",
            arguments: [
                projectID.rawValue, nightStart.rawValue, NightMode.real.rawValue, NightState.closed.rawValue,
                JournalStore.timestamp(openedAt)
            ]
        )
    }
}

@Suite("Night Summary: the unmerged-in-flight-Feature standing line (P12.1)")
struct NightSummaryInFlightFeatureTests {
    @Test("k of N reads the same shape for k = 0 and 0 < k < N, and says unread with no observation yet")
    func kOfNShapesAndUnreadState() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()
        let night = try #require(try journal.currentNight())
        try insertInFlightFeature(journal, featureIssueID: "FEAT-1", repositories: ["backend", "frontend", "docs"])

        let unread = try #require(try NightSummary.inFlightFeatureLines(night: night, journal: journal).first)
        #expect(unread.contains("the merge state has not been read yet"))

        try journal.append(
            .predecessorAncestryObserved(
                featureIssueID: "FEAT-1", mergedRepositories: [], unmergedRepositories: ["backend", "frontend", "docs"]
            ),
            act: .land, runID: RunID(), nightID: night.id
        )
        let kZero = try #require(try NightSummary.inFlightFeatureLines(night: night, journal: journal).first)
        #expect(kZero.contains("0 of 3 Feature Branches merged"))

        try journal.append(
            .predecessorAncestryObserved(
                featureIssueID: "FEAT-1", mergedRepositories: ["backend"], unmergedRepositories: ["frontend", "docs"]
            ),
            act: .land, runID: RunID(), nightID: night.id
        )
        let kMiddle = try #require(try NightSummary.inFlightFeatureLines(night: night, journal: journal).first)
        #expect(kMiddle.contains("1 of 3 Feature Branches merged"))
    }

    @Test("Nights held counts recorded Nights from the selected Night through the reference Night")
    func nightsHeldAcrossSeveralNights() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let day1 = try #require(NightStart(rawValue: "2026-09-10"))
        let day2 = try #require(NightStart(rawValue: "2026-09-12"))
        let day3 = try #require(NightStart(rawValue: "2026-09-15"))
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try insertNightRow(journal, nightStart: day1, openedAt: base, projectID: fixture.projectID)
        try insertNightRow(
            journal, nightStart: day2, openedAt: base.addingTimeInterval(2 * 86400), projectID: fixture.projectID
        )
        try insertNightRow(
            journal, nightStart: day3, openedAt: base.addingTimeInterval(5 * 86400), projectID: fixture.projectID
        )
        let selectedNightID = try #require(try journal.night(id: 1))
        #expect(selectedNightID.nightStart == day1)

        let seeded = try insertInFlightFeature(
            journal, featureIssueID: "FEAT-1", repositories: ["backend"], selectedNightID: 1
        )
        let referenceNight = NightRecord(
            id: 999, projectID: fixture.projectID, nightStart: day3, mode: .real, state: .closed,
            nightCardIssueID: nil, openedAt: base, completedAt: nil, closeReason: nil, verdict: nil, triagedAt: nil
        )

        let line = try #require(try NightSummary.inFlightFeatureLines(night: referenceNight, journal: journal).first)
        #expect(line.contains("in flight for 3 Nights"))
        #expect(seeded.cycleID > 0)
    }

    @Test("A conflict shows only for a Feature Branch that is still unmerged, with its paths")
    func conflictsShownOnlyForUnmergedRepositories() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()
        let night = try #require(try journal.currentNight())
        try insertInFlightFeature(journal, featureIssueID: "FEAT-1", repositories: ["backend", "frontend"])
        try journal.append(
            .predecessorAncestryObserved(
                featureIssueID: "FEAT-1", mergedRepositories: ["backend"], unmergedRepositories: ["frontend"]
            ),
            act: .land, runID: RunID(), nightID: night.id
        )
        try journal.append(
            .mainlineConflictDetected(featureIssueID: "FEAT-1", repository: "backend", paths: ["backend-only.txt"]),
            act: .land, runID: RunID(), nightID: night.id
        )
        try journal.append(
            .mainlineConflictDetected(featureIssueID: "FEAT-1", repository: "frontend", paths: ["frontend-only.txt"]),
            act: .land, runID: RunID(), nightID: night.id
        )

        let line = try #require(try NightSummary.inFlightFeatureLines(night: night, journal: journal).first)
        #expect(line.contains("`frontend`"))
        #expect(line.contains("frontend-only.txt"))
        #expect(!line.contains("backend-only.txt"))
    }

    @Test("The line is absent with nothing in flight, and while the in-flight Cycle has not landed")
    func absentWhenNothingInFlightOrNotLanded() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()
        let night = try #require(try journal.currentNight())

        #expect(try NightSummary.inFlightFeatureLines(night: night, journal: journal).isEmpty)

        try insertInFlightFeature(journal, featureIssueID: "FEAT-1", repositories: ["backend"], landed: false)
        #expect(try NightSummary.inFlightFeatureLines(night: night, journal: journal).isEmpty)
    }

    @Test("A predecessor not landed reads as a quiet Night, naming the Feature and its repositories")
    func predecessorNotLandedIsQuiet() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            work: { context in
                try journal.append(
                    .authoringPredecessorNotLanded(featureIssueID: "FEAT-OLD", repositories: ["backend", "frontend"]),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
            }
        ).run()
        let night = try #require(try journal.currentNight())

        let verdict = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(verdict.contains("did not advance — quiet"))

        let authoringLine = NightCardMaintenance.authoringLine(
            for: .authoringPredecessorNotLanded(featureIssueID: "FEAT-OLD", repositories: ["backend", "frontend"])
        )
        #expect(authoringLine?.contains("`FEAT-OLD`") == true)
        #expect(authoringLine?.contains("backend") == true)
        #expect(authoringLine?.contains("frontend") == true)
    }
}
