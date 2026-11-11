import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// graph-execution/see-and-open-agent-sessions-in-orca, AC touched-session:
// the Night Summary's `**Worker session checks:**` section.

@Suite("Night Summary: Worker session checks")
struct NightSummaryTouchedSessionsTests {
    @Test("Every check names its Card and Round in Journal order")
    func twoCardsRenderTheirRounds() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        _ = try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            work: { context in
                // Card 1 records event in round 1 and round 2
                try journal.append(
                    .agentSessionHadForeignTurns(
                        cardID: 1, issueID: "ENG-1", attemptID: 1, round: 1, cli: "claude",
                        sessionID: "session-1", userCount: 1, assistantCount: 2,
                        firstTimestamp: "2026-11-08T10:00:00Z"
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
                try journal.append(
                    .agentSessionHadForeignTurns(
                        cardID: 1, issueID: "ENG-1", attemptID: 1, round: 2, cli: "claude",
                        sessionID: "session-1", userCount: 1, assistantCount: 2,
                        firstTimestamp: "2026-11-08T10:00:00Z"
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
                // Card 2 records event in round 1
                try journal.append(
                    .agentSessionHadForeignTurns(
                        cardID: 2, issueID: "ENG-4", attemptID: 1, round: 1, cli: "codex",
                        sessionID: "session-1", userCount: 1, assistantCount: 2,
                        firstTimestamp: "2026-11-08T10:00:00Z"
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
            }
        ).run()
        let opened = try #require(try journal.currentNight())

        let lines = try NightSummary.touchedSessionLines(night: opened, journal: journal)

        #expect(lines == [
            "`ENG-1`: its session was continued outside Yellowhammer before Round 1; resumed as usual",
            "`ENG-1`: its session was continued outside Yellowhammer before Round 2; resumed as usual",
            "`ENG-4`: its session was continued outside Yellowhammer before Round 1; resumed as usual"
        ])
    }

    @Test("A Night with no touched session events renders no lines")
    func noEventsRendersNoLines() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        _ = try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()
        let night = try #require(try journal.currentNight())

        let lines = try NightSummary.touchedSessionLines(night: night, journal: journal)

        #expect(lines.isEmpty)
    }

    @Test("The rendered completed block contains the section only when non-empty")
    func renderedBlockOnlyWhenNonEmpty() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        _ = try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()
        let night = try #require(try journal.currentNight())

        let withTouched = NightCardBlock.completed(
            night: night, projectID: journal.projectID, touchedSessions: ["`ENG-1`, `ENG-4`: resumed as usual"]
        )
        #expect(withTouched.contains("**Worker session checks:**"))
        #expect(withTouched.contains("`ENG-1`, `ENG-4`: resumed as usual"))

        let withoutTouched = NightCardBlock.completed(night: night, projectID: journal.projectID)
        #expect(!withoutTouched.contains("**Worker session checks:**"))
    }
}
