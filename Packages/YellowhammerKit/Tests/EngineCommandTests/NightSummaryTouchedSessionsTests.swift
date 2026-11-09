import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// graph-execution/see-and-open-agent-sessions-in-orca, AC touched-session:
// the Night Summary's `**Sessions with turns Yellowhammer did not write:**` section.

@Suite("Night Summary: Sessions with turns Yellowhammer did not write")
struct NightSummaryTouchedSessionsTests {
    @Test("Two Cards' events render as one line naming each Card once in first-seen order with display identifier")
    func twoCardsRenderOneLine() async throws {
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
                        cardID: 1, issueID: "ENG-1", attemptID: 1, round: 1, cli: "claude"
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
                try journal.append(
                    .agentSessionHadForeignTurns(
                        cardID: 1, issueID: "ENG-1", attemptID: 1, round: 2, cli: "claude"
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
                // Card 2 records event in round 1
                try journal.append(
                    .agentSessionHadForeignTurns(
                        cardID: 2, issueID: "ENG-4", attemptID: 1, round: 1, cli: "codex"
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
            }
        ).run()
        let opened = try #require(try journal.currentNight())

        let lines = try NightSummary.touchedSessionLines(night: opened, journal: journal)

        #expect(lines == ["`ENG-1`, `ENG-4`: resumed as usual"])
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
        #expect(withTouched.contains("**Sessions with turns Yellowhammer did not write:**"))
        #expect(withTouched.contains("`ENG-1`, `ENG-4`: resumed as usual"))

        let withoutTouched = NightCardBlock.completed(night: night, projectID: journal.projectID)
        #expect(!withoutTouched.contains("**Sessions with turns Yellowhammer did not write:**"))
    }
}
