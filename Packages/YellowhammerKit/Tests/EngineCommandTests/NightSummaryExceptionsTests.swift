import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// morning-report/write-the-night-summary (roadmap P12.1): the Night Summary's extended
// `**Anomalies:**` section, and the new `**Crashes and reclaims:**` and `**Exceptions:**` sections.
// Reuses `NightCardJournalFixture`, `makeBoards()` and `nightCardNightStart` from NightCardTests.swift.

/// Opens the Project's one Night the way the author Act does. `seed` runs inside the Act's `work`
/// closure, while its Act-scoped lease is still held.
private func openNightForExceptionsTest(
    journal: JournalStore, board: ActBoard, nightStart: NightStart = nightCardNightStart,
    seed: @escaping @Sendable (ActContext) throws -> Void = { _ in }
) async throws -> NightRecord {
    try await EngineInvocation(
        act: .author, mode: .real, nightStart: nightStart, journal: journal,
        trigger: .forced, runID: RunID(), board: board, work: { context in try seed(context) }
    ).run()
    return try #require(try journal.currentNight())
}

/// Inserts a bare Card fixture (no Feature/Cycle context needed), returning its Journal id. Its own
/// Feature, named `featureIssueID`, so a test that inserts more than one Card can give each its own.
@discardableResult
private func insertExceptionsCard(
    _ journal: JournalStore, issueID: String = "CARD-1", featureIssueID: String = "FEAT-1"
) throws -> Int64 {
    try journal.write { db in
        let timestamp = JournalStore.timestamp(Date())
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [featureIssueID, "selected", timestamp]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)", arguments: [featureID, timestamp]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [cycleID, issueID, "backend", "card", 1, CardState.todo.rawValue, 0, timestamp]
        )
        return db.lastInsertedRowID
    }
}

@Suite("Night Summary: Anomalies extension, Crashes and reclaims, Exceptions (P12.1)")
struct NightSummaryExceptionsTests {
    @Test("Anomalies extend with a broken Managed Block delimiter and a broken authoring invariant")
    func anomaliesExtendWithDelimiterAndInvariant() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForExceptionsTest(journal: journal, board: board) { context in
            try journal.append(
                .managedBlockDelimiterBroken(issueID: "CARD-1"), act: context.act, runID: context.runID,
                nightID: context.night.id
            )
            try journal.append(
                .authoringInvariantBroken(cardID: 1, issueID: "CARD-2", reason: "stale Worktree"),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
        }

        let lines = try NightSummary.anomalyLines(night: night, journal: journal)
        #expect(lines.contains { $0.contains("`CARD-1`'s Managed Block delimiter was broken") })
        #expect(lines.contains("`CARD-2` violates an authoring invariant: stale Worktree."))
    }

    @Test("A reclaimed Card Lease reads the mandated 'reclaimable, no partial state' wording")
    func cardLeaseReclaimedUsesMandatedWording() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let cardID = try insertExceptionsCard(journal)
        let previous = RunID()
        let night = try await openNightForExceptionsTest(journal: journal, board: board) { context in
            try journal.append(
                .cardLeaseReclaimed(cardID: cardID, previousRunID: previous, expiredAt: Date()),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
        }

        let lines = try NightSummary.crashesAndReclaimsLines(night: night, journal: journal)
        #expect(lines.count == 1)
        #expect(lines[0].contains("`CARD-1`"))
        #expect(lines[0].contains("the Card is reclaimable, and no partial state was written as if it were complete"))
        #expect(!lines[0].contains("continues"))
    }

    @Test("A reclaimed Card names the classified Attempt's outcome and route exclusion")
    func cardReclaimedNamesAttemptOutcome() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let previous = RunID()
        let night = try await openNightForExceptionsTest(journal: journal, board: board) { context in
            try journal.append(
                .cardReclaimed(
                    cardID: 1, issueID: "CARD-1", previousRunID: previous, attemptID: 7,
                    outcome: "Crashed-Unknown", routeExcluded: false
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
        }

        let lines = try NightSummary.crashesAndReclaimsLines(night: night, journal: journal)
        #expect(lines[0].contains("the Card is reclaimable, and no partial state was written as if it were complete"))
        #expect(lines[0].contains("Attempt `7` was classified Crashed-Unknown, its Route not excluded."))
    }

    @Test("Two reclaimed Cards: one whose run was stopped by the engine, one an ordinary crash — each its own line")
    func cardReclaimedDistinguishesEngineStopFromCrash() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let stoppedCardID = try insertExceptionsCard(journal, issueID: "CARD-1", featureIssueID: "FEAT-1")
        let crashedCardID = try insertExceptionsCard(journal, issueID: "CARD-2", featureIssueID: "FEAT-2")
        let stoppedRun = RunID()
        let crashedRun = RunID()
        let night = try await openNightForExceptionsTest(journal: journal, board: board) { context in
            try journal.append(
                .cardRunStep(
                    cardID: stoppedCardID, issueID: "CARD-1", step: .leaseLeftToExpire, detail: "heartbeat failed"
                ),
                act: context.act, runID: stoppedRun, nightID: context.night.id
            )
            try journal.append(
                .cardReclaimed(
                    cardID: stoppedCardID, issueID: "CARD-1", previousRunID: stoppedRun, attemptID: 1,
                    outcome: "Crashed-Unknown", routeExcluded: false
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            try journal.append(
                .cardReclaimed(
                    cardID: crashedCardID, issueID: "CARD-2", previousRunID: crashedRun, attemptID: 2,
                    outcome: "Crashed-Unknown", routeExcluded: false
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
        }

        let lines = try NightSummary.crashesAndReclaimsLines(night: night, journal: journal)
        #expect(lines.count == 2)
        let mandatedWording = "the Card is reclaimable, and no partial state was written as if it were complete"
        let stoppedLine = try #require(lines.first { $0.contains("`CARD-1`") })
        #expect(stoppedLine.contains("was stopped by the engine: heartbeat failed"))
        #expect(stoppedLine.contains(mandatedWording))
        let crashedLine = try #require(lines.first { $0.contains("`CARD-2`") })
        #expect(!crashedLine.contains("stopped by the engine"))
        #expect(crashedLine.contains(mandatedWording))
    }

    @Test("Expired Card Leases swept names every swept Card")
    func expiredCardLeasesSweptNamesCards() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let cardID = try insertExceptionsCard(journal)
        let night = try await openNightForExceptionsTest(journal: journal, board: board) { context in
            try journal.append(
                .expiredCardLeasesSwept(cycleID: 1, reclaimedCardIDs: [cardID]),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
        }

        let lines = try NightSummary.crashesAndReclaimsLines(night: night, journal: journal)
        #expect(lines[0].contains("`CARD-1`"))
        #expect(lines[0].contains("reclaimable, and no partial state was written as if it were complete"))
    }

    @Test("An opened-and-died prior Night is named by its night_start")
    func openedAndDiedNamesDeadNight() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        _ = try await openNightForExceptionsTest(journal: journal, board: board)

        let secondNightStart = try #require(NightStart(rawValue: "2026-09-16"))
        let secondNight = try await openNightForExceptionsTest(
            journal: journal, board: board, nightStart: secondNightStart
        )

        let lines = try NightSummary.crashesAndReclaimsLines(night: secondNight, journal: journal)
        #expect(lines.contains { $0.contains("Night `2026-09-15` opened and died") })
    }

    @Test("Exceptions list a refused Override once per Card and reason, however many Acts refused it")
    func exceptionsListARefusedOverrideOnce() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let reason = "Override `agy/opus/max` failed its Route Pre-flight on `agy/opus/max`: "
            + "`agy` rejected model `opus`"
        let night = try await openNightForExceptionsTest(journal: journal, board: board) { context in
            for _ in 0..<2 {
                try journal.append(
                    .overrideRefused(cardID: 1, issueID: "CARD-1", reason: reason),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
            }
        }

        let lines = try NightSummary.exceptionLines(night: night, journal: journal)
        #expect(lines == ["`CARD-1` was not dispatched and spent no Attempt: \(reason)."])
    }

    @Test("Exceptions render a Worktree branch-name collision that halted the build Act")
    func exceptionsRenderWorktreeNameCollision() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForExceptionsTest(journal: journal, board: board) { context in
            try journal.append(
                .worktreeNameCollision(
                    repository: "backend", requested: "rozd/yh-x", reported: "yh-x"
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
        }

        let lines = try NightSummary.exceptionLines(night: night, journal: journal)
        #expect(lines.contains {
            $0 == "A Worktree branch-name collision in `backend` halted the build Act: Orca ADE made `yh-x`, "
                + "not `rozd/yh-x`. Later Acts retry."
        })
    }

    @Test("Exceptions name a Feature Branch the ghost purge could not recover: Feature, repo, tip, Done Cards (OQ133)")
    func exceptionsNameAnUnrecoveredFeatureBranch() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let cardID = try insertExceptionsCard(journal, issueID: "CARD-1", featureIssueID: "FEAT-1")
        let cycleID = try journal.card(id: cardID).cycleID
        let featureID = try journal.read { db in
            try #require(try Int64.fetchOne(db, sql: "SELECT feature_id FROM cycle WHERE id = ?", arguments: [cycleID]))
        }
        let night = try await openNightForExceptionsTest(journal: journal, board: board) { context in
            try journal.append(
                .worktreeLost(
                    featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
                    pinnedCommit: nil, lostCommit: "abc123def", lostDoneCardIDs: [cardID]
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
        }

        let lines = try NightSummary.exceptionLines(night: night, journal: journal)
        #expect(lines.contains(
            "Feature `FEAT-1`'s Worktree in `backend` was removed outside Yellowhammer, taking its Feature "
                + "Branch, and nothing could be recovered. Last known-good commit: `abc123def` is gone from the "
                + "repository. Done Work Cards whose commits are gone: `CARD-1`. Re-readying them is the "
                + "Operator's gesture."
        ))
    }

    @Test("A ghost purge that pinned a commit, or lost nothing, adds no line to Exceptions (OQ133)")
    func exceptionsStaySilentWhenNothingIsLost() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForExceptionsTest(journal: journal, board: board) { context in
            try journal.append(
                .worktreeLost(
                    featureID: 1, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1", pinnedCommit: "abc123"
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            // Pushed work survives on the remote: nothing recoverable, but nothing lost to name either.
            try journal.append(
                .worktreeLost(
                    featureID: 1, repository: "frontend", worktreeID: "wt-2", path: "/tmp/wt-2", pinnedCommit: nil
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
        }

        let lines = try NightSummary.exceptionLines(night: night, journal: journal)
        #expect(!lines.contains { $0.contains("was removed outside Yellowhammer") })
    }

    @Test("A lane with no recorded tip names the Done Cards and says so (OQ133)")
    func exceptionsNameLostDoneCardsWithoutARecordedTip() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let first = try insertExceptionsCard(journal, issueID: "CARD-1", featureIssueID: "FEAT-1")
        let second = try insertExceptionsCard(journal, issueID: "CARD-2", featureIssueID: "FEAT-2")
        let night = try await openNightForExceptionsTest(journal: journal, board: board) { context in
            try journal.append(
                .worktreeLost(
                    featureID: 999, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
                    pinnedCommit: nil, lostCommit: nil, lostDoneCardIDs: [first, second]
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
        }

        let lines = try NightSummary.exceptionLines(night: night, journal: journal)
            .filter { $0.contains("was removed outside Yellowhammer") }
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("Feature #999's Worktree in `backend`"))
        #expect(lines[0].contains("Last known-good commit: none was recorded."))
        #expect(lines[0].contains("`CARD-1`, `CARD-2`"))
    }

    @Test("""
        Exceptions render boardWriteFailed, rateBudgetExhausted, mainlineFetchFailed, absentNightDetected, \
        notificationDeliveryFailed
        """)
    func exceptionsRenderEveryKind() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForExceptionsTest(journal: journal, board: board) { context in
            try journal.append(
                .boardWriteFailed(clientID: UUID(), operation: "updateIssue", issueID: "CARD-1", reason: "refused"),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            try journal.append(
                .rateBudgetExhausted(degradation: "reads only"), act: context.act, runID: context.runID,
                nightID: context.night.id
            )
            try journal.append(
                .rateBudgetExhausted(
                    degradation: "writes deferred",
                    installation: AppInstallationLabel(
                        name: "acme", workspace: BoardObjectID(rawValue: "workspace-1")
                    )
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            try journal.append(
                .mainlineFetchFailed(repository: "backend", reason: "network"), act: context.act,
                runID: context.runID, nightID: context.night.id
            )
            try journal.append(
                .absentNightDetected(nightStart: try #require(NightStart(rawValue: "2026-09-10"))),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            try journal.append(
                .notificationDeliveryFailed(notification: "night_summary", reason: "unreachable"),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
        }

        let lines = try NightSummary.exceptionLines(night: night, journal: journal)
        #expect(lines.contains { $0.contains("updateIssue") && $0.contains("`CARD-1`") && $0.contains("refused") })
        #expect(lines.contains {
            $0 == "The board's request budget was exhausted installation-wide: reads only."
        })
        #expect(lines.contains {
            $0.contains("installation-wide, on Linear workspace \"acme\"") && $0.contains("writes deferred")
        })
        #expect(lines.contains { $0.contains("`backend`") && $0.contains("network") })
        #expect(lines.contains { $0.contains("2026-09-10") })
        #expect(lines.contains { $0.contains("night_summary") && $0.contains("unreachable") })
    }

    @Test("An abandoned Feature's predecessor walk names it in the Authoring section")
    func abandonedFeatureAuthoringLine() {
        let line = NightCardMaintenance.authoringLine(
            for: .predecessorWalkSkippedReleasedFeature(featureIssueID: "FEAT-OLD")
        )
        #expect(line?.contains("Feature `FEAT-OLD` was abandoned") == true)
        #expect(line?.contains("tonight's work is not built on it") == true)
    }

    @Test("A crashed Night's verdict is promoted to the front, and the Crashes section names what was reclaimed")
    func crashedNightVerdictAndSection() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        _ = try await openNightForExceptionsTest(journal: journal, board: board)

        let secondNightStart = try #require(NightStart(rawValue: "2026-09-16"))
        let cardID = try insertExceptionsCard(journal)
        let previous = RunID()
        try await EngineInvocation(
            act: .land, mode: .real, nightStart: secondNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board,
            work: { context in
                try journal.append(
                    .cardLeaseReclaimed(cardID: cardID, previousRunID: previous, expiredAt: Date()),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
            }
        ).run()

        let issue = try #require(await boards.writing.liveIssues.first { $0.title == "Night \(secondNightStart)" })
        let description = try #require(issue.description)
        #expect(description.contains("**Verdict:** crashed · "))
        #expect(description.contains("**Crashes and reclaims:**"))
        #expect(description.contains("`CARD-1`"))
        #expect(description.contains("reclaimable, and no partial state was written as if it were complete"))
        #expect(!description.contains("repo_lanes_in_parallel"))
        #expect(!description.contains("spend_per_night_usd"))
    }
}
