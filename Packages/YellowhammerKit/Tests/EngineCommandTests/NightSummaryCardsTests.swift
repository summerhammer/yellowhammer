import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// morning-report/write-the-night-summary (roadmap P12.1): the Night Summary's `**Cards:**`,
// `**Dispositions:**`, `**Pull requests:**` and `**Answers on landed Cards:**` sections. Reuses
// `NightCardJournalFixture`, `makeBoards()` and `nightCardNightStart` from NightCardTests.swift.

private let codexRoute = Route(cli: "codex", model: "gpt-5.4", effort: "medium")!
private let agyRoute = Route(cli: "agy", model: "gemini-3.8-flash", effort: "high")!

/// A structural failure cause for the recurrence tests — its wording is never asserted, only its hash.
private func flakyCause() throws -> FailureCause {
    try #require(FailureCause(ending: .hardFailure(.reported(reason: "flaky"))))
}

/// Opens the Project's one Night the way the author Act does. `seed` runs inside the Act's `work`
/// closure, while its Act-scoped lease is still held — any Journal write that revalidates the lease
/// (`recordAttempt`, `recordRound`, `endAttempt`, `recordFailureCause`, ...) must happen there, since
/// `.run()` releases the lease before returning.
private func openNightForCardsTest(
    journal: JournalStore, board: ActBoard, seed: @escaping @Sendable (ActContext) throws -> Void = { _ in }
) async throws -> NightRecord {
    try await EngineInvocation(
        act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
        trigger: .forced, runID: RunID(), board: board, work: { context in try seed(context) }
    ).run()
    return try #require(try journal.currentNight())
}

/// A Feature/Cycle/Card fixture's Journal ids.
private struct CardsFixtureIDs {
    let featureID: Int64
    let cycleID: Int64
    let cardID: Int64
}

/// Inserts a Feature/Cycle/Card fixture, returning their Journal ids.
@discardableResult
private func insertCardsFixture(
    _ journal: JournalStore, featureIssueID: String = "FEAT-1", cardIssueID: String = "CARD-1",
    repository: String = "backend", authoredOrder: Int = 1, cardState: CardState = .todo,
    issueIDForDisplay: String? = nil, issueKey: String? = nil, issueURL: String? = nil
) throws -> CardsFixtureIDs {
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
            INSERT INTO card (
                cycle_id, issue_id, issue_id_for_display, issue_key, issue_url, repository, kind, authored_order,
                state, budget_epoch, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, cardIssueID, issueIDForDisplay, issueKey, issueURL, repository, "card", authoredOrder,
                cardState.rawValue, 0, timestamp
            ]
        )
        return CardsFixtureIDs(featureID: featureID, cycleID: cycleID, cardID: db.lastInsertedRowID)
    }
}

/// A second Attempt whose Check failed on `fddeef4` (a failed Round) and then passed on `b763aff` (no
/// Round: only a failed judgement is one), ending in success.
private func seedCheckFailedThenPassed(
    _ journal: JournalStore, context: ActContext, cardID: Int64, issueID: String
) throws {
    let attempt = try journal.recordAttempt(
        cardID: cardID, route: agyRoute, runID: context.runID, act: context.act, nightID: context.night.id
    )
    try journal.append(
        .checkRan(
            cardID: cardID, issueID: issueID, attemptID: attempt.id, result: .failed, exitStatus: 1,
            output: "red", judgedCommit: "fddeef4"
        ),
        act: context.act, runID: context.runID, nightID: context.night.id
    )
    try journal.recordRound(
        attemptID: attempt.id, lens: .check, verdict: "failed", requestedChanges: "red",
        judgedCommit: "fddeef4", runID: context.runID
    )
    try journal.append(
        .checkRan(
            cardID: cardID, issueID: issueID, attemptID: attempt.id, result: .passed, exitStatus: 0,
            output: nil, judgedCommit: "b763aff"
        ),
        act: context.act, runID: context.runID, nightID: context.night.id
    )
    try journal.endAttempt(
        attemptID: attempt.id, ending: .success, runID: context.runID, act: context.act, nightID: context.night.id
    )
}

@Suite("Night Summary: Cards, Dispositions, Pull requests, Answers (P12.1)")
struct NightSummaryCardsTests {
    @Test("No section renders when no Card was touched this Night")
    func noSectionsWhenNothingTouched() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForCardsTest(journal: journal, board: board)

        #expect(try NightSummary.cardLines(night: night, journal: journal).isEmpty)
        #expect(try NightSummary.dispositionLines(night: night, journal: journal).isEmpty)
    }

    @Test("A Card's name, state, Attempt, Check result and Rounds render in one line")
    func cardLineNamesRouteCheckAndRounds() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let seeded = try insertCardsFixture(journal)
        let night = try await openNightForCardsTest(journal: journal, board: board) { context in
            let attempt = try journal.recordAttempt(
                cardID: seeded.cardID, route: codexRoute, runID: context.runID, act: context.act,
                nightID: context.night.id
            )
            try journal.recordRound(
                attemptID: attempt.id, lens: .review, verdict: "changes-requested", requestedChanges: nil,
                judgedCommit: nil, runID: context.runID
            )
            // A passing Check writes no Round: only its `checkRan` event records it.
            try journal.append(
                .checkRan(
                    cardID: seeded.cardID, issueID: "CARD-1", attemptID: attempt.id, result: .passed,
                    exitStatus: 0, output: nil, judgedCommit: "abc1234"
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            try journal.endAttempt(
                attemptID: attempt.id, ending: .success, runID: context.runID, act: context.act,
                nightID: context.night.id
            )
        }

        let lines = try NightSummary.cardLines(night: night, journal: journal)
        #expect(lines == [
            "`CARD-1` — Todo · Attempt 1: codex/gpt-5.4, success; check: passed on `abc1234`; "
                + "rounds: review(changes-requested)"
        ])
    }

    @Test("A Done Card whose Check failed and then passed reports the pass, not the stale failure (#384)")
    func checkFailedThenPassedReadsPassed() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let url = "https://linear.app/summerhammer/issue/YLH-312"
        let issueID = "88d41e5f-0000-4000-8000-000000000312"
        let seeded = try insertCardsFixture(
            journal, cardIssueID: issueID, cardState: .done,
            issueIDForDisplay: "YLH-312", issueKey: "YLH-312", issueURL: url
        )
        let night = try await openNightForCardsTest(journal: journal, board: board) { context in
            let first = try journal.recordAttempt(
                cardID: seeded.cardID, route: agyRoute, runID: context.runID, act: context.act,
                nightID: context.night.id
            )
            try journal.endAttempt(
                attemptID: first.id,
                ending: .crashedUnknown(.terminated(.timedOut(after: .seconds(1800), forcedKill: false))),
                runID: context.runID, act: context.act, nightID: context.night.id
            )
            try seedCheckFailedThenPassed(journal, context: context, cardID: seeded.cardID, issueID: issueID)
        }

        let line = try #require(try NightSummary.cardLines(night: night, journal: journal).first)
        #expect(line.hasPrefix("[YLH-312](\(url)) — Done"))
        #expect(line.contains("Attempt 1: agy/gemini-3.8-flash, Crashed-Unknown ("))
        #expect(line.contains("Attempt 2: agy/gemini-3.8-flash, success"))
        #expect(line.contains("check: passed on `b763aff` after 1 failed run"))
        #expect(!line.contains("check: failed"))
        #expect(line.contains("rounds: check(failed)"))
    }

    @Test("A Card without a URL is named in backticks; without an identifier, by its issue id")
    func cardNameFallsBack() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let keyed = try insertCardsFixture(
            journal, featureIssueID: "FEAT-1", cardIssueID: "uuid-keyed", repository: "backend",
            issueKey: "YLH-7"
        )
        let bare = try insertCardsFixture(
            journal, featureIssueID: "FEAT-2", cardIssueID: "uuid-bare", repository: "frontend"
        )
        let night = try await openNightForCardsTest(journal: journal, board: board)
        for (id, issueID) in [(keyed.cardID, "uuid-keyed"), (bare.cardID, "uuid-bare")] {
            try journal.append(
                .cardRunStep(cardID: id, issueID: issueID, step: .leaseClaimed, detail: nil),
                act: .build, runID: RunID(), nightID: night.id
            )
        }

        let lines = try NightSummary.cardLines(night: night, journal: journal)
        #expect(lines == [
            "`YLH-7` — Todo · no Attempt this Night.",
            "`uuid-bare` — Todo · no Attempt this Night."
        ])
    }

    @Test("Dispositions name a failure cause's and an Operator abort's Card by identifier, not UUID")
    func dispositionsNameCardsByIdentifier() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let issueID = "88d41e5f-0000-4000-8000-000000000312"
        let seeded = try insertCardsFixture(
            journal, cardIssueID: issueID, cardState: .blocked,
            issueIDForDisplay: "YLH-312"
        )
        let night = try await openNightForCardsTest(journal: journal, board: board) { context in
            try journal.recordFailureCause(
                cardID: seeded.cardID, cause: try flakyCause(),
                nightID: context.night.id, runID: context.runID, act: context.act
            )
            try journal.append(
                .cardRunStep(
                    cardID: seeded.cardID, issueID: issueID, step: .operatorAborted, detail: "attempt 2"
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
        }

        let lines = try NightSummary.dispositionLines(night: night, journal: journal)
        #expect(lines.contains("`YLH-312` — first occurrence."))
        #expect(lines.contains { $0.hasPrefix("`YLH-312` was stopped by the Operator: Attempt 2 aborted") })
        #expect(!lines.contains { $0.contains(issueID) })
    }

    @Test("A model-alone Check reads `check = none`")
    func modelAloneCheckReadsBack() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let seeded = try insertCardsFixture(journal)
        let night = try await openNightForCardsTest(journal: journal, board: board) { context in
            let attempt = try journal.recordAttempt(
                cardID: seeded.cardID, route: codexRoute, checkDeclaredNone: true, runID: context.runID,
                act: context.act, nightID: context.night.id
            )
            try journal.endAttempt(
                attemptID: attempt.id, ending: .success, runID: context.runID, act: context.act,
                nightID: context.night.id
            )
        }

        let lines = try NightSummary.cardLines(night: night, journal: journal)
        #expect(lines.first?.contains("check: green came from a model alone (`check = none`)") == true)
    }

    @Test("Cards touched this Night are sorted by repository then authored order")
    func cardsSortedByRepositoryThenAuthoredOrder() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForCardsTest(journal: journal, board: board)
        let second = try insertCardsFixture(
            journal, featureIssueID: "FEAT-1", cardIssueID: "FRONT-2", repository: "frontend", authoredOrder: 1
        )
        let first = try insertCardsFixture(
            journal, featureIssueID: "FEAT-2", cardIssueID: "BACK-1", repository: "backend", authoredOrder: 1
        )
        try journal.append(
            .cardRunStep(cardID: second.cardID, issueID: "FRONT-2", step: .leaseClaimed, detail: nil),
            act: .build, runID: RunID(), nightID: night.id
        )
        try journal.append(
            .cardRunStep(cardID: first.cardID, issueID: "BACK-1", step: .leaseClaimed, detail: nil),
            act: .build, runID: RunID(), nightID: night.id
        )

        let lines = try NightSummary.cardLines(night: night, journal: journal)
        #expect(lines.count == 2)
        #expect(lines[0].contains("BACK-1"))
        #expect(lines[1].contains("FRONT-2"))
    }

    @Test("Dispositions counts Blocked and Waiting on You, and names recurrence vs first occurrence")
    func dispositionsCountsAndNamesRecurrence() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let blocked = try insertCardsFixture(
            journal, featureIssueID: "FEAT-1", cardIssueID: "CARD-1", cardState: .blocked
        )
        let waiting = try insertCardsFixture(
            journal, featureIssueID: "FEAT-2", cardIssueID: "CARD-2", repository: "frontend", cardState: .waitingOnYou
        )
        let night = try await openNightForCardsTest(journal: journal, board: board) { context in
            try journal.append(
                .cardRunStep(cardID: blocked.cardID, issueID: "CARD-1", step: .leaseClaimed, detail: nil),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            try journal.recordFailureCause(
                cardID: blocked.cardID, cause: try flakyCause(),
                nightID: context.night.id, runID: context.runID, act: context.act
            )
            try journal.append(
                .cardRunStep(cardID: waiting.cardID, issueID: "CARD-2", step: .leaseClaimed, detail: nil),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
        }

        let lines = try NightSummary.dispositionLines(night: night, journal: journal)
        #expect(lines.first == "1 Blocked, 1 Waiting on You")
        #expect(lines.contains("`CARD-1` — first occurrence."))
    }

    @Test("A second Night's recorded failure cause reads back as a recurrence")
    func failureCauseRecurrenceIsNamed() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let seeded = try insertCardsFixture(journal, cardState: .blocked)
        _ = try await openNightForCardsTest(journal: journal, board: board) { context in
            try journal.recordFailureCause(
                cardID: seeded.cardID, cause: try flakyCause(),
                nightID: context.night.id, runID: context.runID, act: context.act
            )
        }

        let secondNightStart = try #require(NightStart(rawValue: "2026-09-16"))
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: secondNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            work: { context in
                try journal.append(
                    .cardRunStep(cardID: seeded.cardID, issueID: "CARD-1", step: .leaseClaimed, detail: nil),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
                try journal.recordFailureCause(
                    cardID: seeded.cardID,
                    cause: try flakyCause(),
                    nightID: context.night.id, runID: context.runID, act: context.act
                )
            }
        ).run()
        let secondNight = try #require(try journal.currentNight())

        let lines = try NightSummary.dispositionLines(night: secondNight, journal: journal)
        #expect(lines.contains("`CARD-1` — recurrence."))
    }

    @Test("Pull requests render per repository, flagged Partial Landing when their Cycle has lane holes")
    func pullRequestsFlagPartialLanding() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForCardsTest(journal: journal, board: board)
        let clean = try insertCardsFixture(
            journal, featureIssueID: "FEAT-1", cardIssueID: "CARD-1", cardState: .done
        )
        let partial = try insertCardsFixture(
            journal, featureIssueID: "FEAT-2", cardIssueID: "CARD-2", repository: "frontend", cardState: .blocked
        )
        try journal.recordPullRequest(
            featureID: clean.featureID, repository: "backend", url: "https://example.com/pr/1", nightID: night.id,
            runID: RunID()
        )
        try journal.recordPullRequest(
            featureID: partial.featureID, repository: "frontend", url: nil, nightID: night.id, runID: RunID()
        )

        let lines = try NightSummary.pullRequestLines(night: night, journal: journal)
        #expect(lines.contains("`backend`: https://example.com/pr/1"))
        #expect(lines.contains("`frontend`: no url recorded (Partial Landing)"))
    }

    @Test("A rehearsal Night's un-opened pull request reads back as not opened")
    func rehearsalPullRequestNotOpened() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForCardsTest(journal: journal, board: board)
        try journal.append(
            .landStep(step: .openPullRequest, repository: "backend", outcome: .rehearsalBoundary, detail: nil),
            act: .land, runID: RunID(), nightID: night.id
        )

        let lines = try NightSummary.pullRequestLines(night: night, journal: journal)
        #expect(lines == ["`backend`: not opened — rehearsal."])
    }

    @Test("An answer banked on landing appears only on the Night it arrived")
    func answerAppearsOnlyOnArrivalNight() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let firstNight = try await openNightForCardsTest(journal: journal, board: board)
        try journal.append(
            .waitingOnYouReplyBanked(cardID: 1, issueID: "CARD-1", commentID: "c1"),
            act: .land, runID: RunID(), nightID: firstNight.id
        )
        try journal.releaseActLease(runID: RunID())

        let secondNightStart = try #require(NightStart(rawValue: "2026-09-16"))
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: secondNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()
        let secondNight = try #require(try journal.currentNight())

        let firstLines = try NightSummary.answerLines(night: firstNight, journal: journal)
        let secondLines = try NightSummary.answerLines(night: secondNight, journal: journal)
        #expect(firstLines == ["`CARD-1`'s Waiting on You answer was banked on landing."])
        #expect(secondLines.isEmpty)
    }

    @Test("The Cards and Dispositions sections render through acceptCompletion against a fake board")
    func acceptCompletionRendersCardsAndDispositions() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let seeded = try insertCardsFixture(journal, cardState: .blocked)
        _ = try await openNightForCardsTest(journal: journal, board: board) { context in
            let attempt = try journal.recordAttempt(
                cardID: seeded.cardID, route: codexRoute, runID: context.runID, act: context.act,
                nightID: context.night.id
            )
            try journal.endAttempt(
                attemptID: attempt.id, ending: .success, runID: context.runID, act: context.act,
                nightID: context.night.id
            )
        }

        try await EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board, work: { _ in }
        ).run()

        let issue = try #require(await boards.writing.liveIssues.first)
        let description = try #require(issue.description)
        #expect(description.contains("**Cards:**"))
        #expect(description.contains(
            "`CARD-1` — Blocked · Attempt 1: codex/gpt-5.4, success; check: not run"
        ))
        #expect(description.contains("**Dispositions:**"))
        #expect(description.contains("1 Blocked, 0 Waiting on You"))
    }
}
