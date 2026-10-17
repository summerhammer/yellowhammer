import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// morning-report/write-the-night-summary#failure-line and morning-report/disclose-a-failure: the Night Card's
// `**Failures:**` section. Reuses `NightCardJournalFixture`, `makeBoards()` and `nightCardNightStart` from
// NightCardTests.swift and `appendSeededRun` from NightSummaryVerdictTests.swift. Asserts the engine's own
// wording only — never anything a model authored.

private let utc = TimeZone(identifier: "UTC") ?? .gmt

private let overBudget = "Work Card \"T\" (seshes-backend) composes 12,153 UTF-16 code units, over the description "
    + "budget of 10,000: Brief 7,000"

/// Opens the Project's one Night the way the author Act does.
private func openFailureNight(journal: JournalStore, board: ActBoard) async throws -> NightRecord {
    try await EngineInvocation(
        act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
        trigger: .forced, runID: RunID(), board: board, work: { _ in }
    ).run()
    return try #require(try journal.currentNight())
}

/// Appends `events`, each `offset` seconds after `start`, to one run of `act`.
private func appendRun(
    to journal: JournalStore, night: NightRecord, act: Act, runID: RunID = RunID(), startedAt: String,
    _ events: [(TimeInterval, JournalEvent)]
) throws {
    let start = try seededInstant(startedAt)
    try journal.append(.actStarted, act: act, runID: runID, nightID: night.id, now: start)
    for (offset, event) in events {
        try journal.append(event, act: act, runID: runID, nightID: night.id, now: start.addingTimeInterval(offset))
    }
}

@Suite("Night Summary: the Failures section")
struct NightSummaryFailureLinesTests {
    private func lines(
        _ night: NightRecord, _ journal: JournalStore, renderingRunID: RunID? = nil
    ) throws -> [String] {
        try NightSummary.failureLines(
            night: night, journal: journal, renderingRunID: renderingRunID, consecutiveAuthoringFaultsMax: 3,
            timeZone: utc
        )
    }

    @Test("A recovered board-scope failure is gone; the over-budget fault of the recovering run is the one notice")
    func seshesNight() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openFailureNight(journal: journal, board: board)
        try appendRun(
            to: journal, night: night, act: .author, startedAt: "2026-10-08T14:00:00Z",
            [
                (1, .boardScopeUnresolved(steps: "no Linear project")),
                (2, .actIncomplete(reason: "\(ActFailureCause.boardScopePrefix): no Linear project"))
            ]
        )
        try appendRun(
            to: journal, night: night, act: .author, startedAt: "2026-10-08T14:28:00Z",
            [
                (5, .authoringDispatched(pass: .selection, route: "primary", ordinal: 1, fixture: nil)),
                (10, .featureBreakdownRejected(name: "Sync", reason: overBudget)),
                (11, .actEnded)
            ]
        )

        let bullets = try lines(night, journal)
        #expect(bullets.count == 1)
        let bullet = try #require(bullets.first)
        #expect(
            bullet.hasPrefix(
                "**Authoring \u{201C}Sync\u{201D} failed: over the description budget** — cause: over the "
                    + "description budget;"
            )
        )
        #expect(bullet.contains("Details: see Authoring below"))
        #expect(bullet.contains("after 3 faults in a row"))
        #expect(bullet.contains("Settings › Board connections"))
    }

    @Test("Five failed land runs in a row are one notice, with their span and the Act's log under ~")
    func repeatedFailureIsOneNotice() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openFailureNight(journal: journal, board: board)
        for minute in [1, 11, 21, 31, 41] {
            let at = String(format: "2026-10-08T00:%02d:00Z", minute)
            try appendSeededRun(to: journal, night: night, startedAt: at, ending: .halted)
        }

        let bullets = try lines(night, journal)
        #expect(bullets.count == 1)
        let bullet = try #require(bullets.first)
        #expect(bullet.hasPrefix("**The land Act could not complete** · 5 times, 00:01–00:41 — cause: "))
        #expect(bullet.contains("the land Act's log, `~/Library/Logs/Yellowhammer/fixture.land.log`"))
        #expect(bullet.contains("Next: the next land Act tries again"))
    }

    @Test("A failure a later run recovered gets no bullet, and a quiet Night renders no Failures section")
    func recoveredAndQuietNights() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openFailureNight(journal: journal, board: board)
        #expect(try lines(night, journal).isEmpty)

        try appendSeededRun(to: journal, night: night, startedAt: "2026-10-08T00:01:00Z", ending: .halted)
        try appendSeededRun(to: journal, night: night, startedAt: "2026-10-08T00:15:00Z", ending: .ended)
        #expect(try lines(night, journal).isEmpty)

        let block = NightCardBlock.completed(night: night, projectID: journal.projectID)
        #expect(!block.contains("**Failures:**"))
    }

    @Test("The Failures section sits right after the Verdict line, before every other section")
    func sectionOrder() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openFailureNight(journal: journal, board: board)

        let block = NightCardBlock.completed(
            night: night, projectID: journal.projectID, failureLines: ["**A failure** — cause: x."],
            authoringFindings: ["a finding"], cardLines: ["a card"], exceptions: ["an exception"]
        )
        let verdict = try #require(block.range(of: "**Verdict:**"))
        let failures = try #require(block.range(of: "\n\n**Failures:**\n- **A failure** — cause: x."))
        let authoring = try #require(block.range(of: "**Authoring:**"))
        let cards = try #require(block.range(of: "**Cards:**"))
        #expect(verdict.upperBound < failures.lowerBound)
        #expect(block[verdict.upperBound..<failures.lowerBound].contains("\n") == false)
        #expect(failures.upperBound < authoring.lowerBound)
        #expect(authoring.lowerBound < cards.lowerBound)
    }

    @Test("Failures that are no Act failure get one pointer bullet, only for what happened")
    func alsoThisNight() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openFailureNight(journal: journal, board: board)
        try appendRun(
            to: journal, night: night, act: .build, startedAt: "2026-10-08T01:00:00Z",
            [
                (1, .boardWriteFailed(
                    clientID: UUID(), operation: "updateIssue", issueID: "CARD-1", reason: "refused"
                )),
                (2, .leaseReclaimed(previousRunID: RunID(), previousAct: .build, expiredAt: Date())),
                (3, .landStep(step: .push, repository: "backend", outcome: .failed, detail: nil)),
                (4, .actEnded)
            ]
        )
        try appendSeededRun(to: journal, night: night, startedAt: "2026-10-08T02:00:00Z", ending: .unterminated)

        let bullets = try lines(night, journal)
        #expect(
            bullets == [
                "Also this Night: 1 board write failed permanently — see Exceptions below, "
                    + "1 crash or reclaimed Lease — see Crashes and reclaims below, "
                    + "1 crashed run — see the Night's account in Yellowhammer, "
                    + "1 failed landing step — see the Night's account in Yellowhammer."
            ]
        )
    }

    @Test("The closing land's completed Night Card carries the failure line")
    func nightCardCarriesTheFailureLine() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        _ = try await openFailureNight(journal: journal, board: board)

        let secondNightStart = try #require(NightStart(rawValue: "2026-09-16"))
        try await EngineInvocation(
            act: .land, mode: .real, nightStart: secondNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board,
            work: { context in
                try journal.append(
                    .featureBreakdownRejected(name: "Sync", reason: overBudget),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
            }
        ).run()

        let issue = try #require(await boards.writing.liveIssues.first { $0.title == "Night \(secondNightStart)" })
        let description = try #require(issue.description)
        #expect(description.contains("**Failures:**"))
        #expect(description.contains("**Authoring \u{201C}Sync\u{201D} failed: over the description budget**"))
        let verdict = try #require(description.range(of: "**Verdict:**"))
        let failures = try #require(description.range(of: "**Failures:**"))
        #expect(verdict.upperBound < failures.lowerBound)
    }
}
