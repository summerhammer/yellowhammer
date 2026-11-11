import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// graph-execution/see-and-open-agent-sessions-in-orca, AC orca-unreachable:
// the Night Summary's `**Passes not shown in Orca:**` section; morning-report/write-the-night-summary,
// AC orca-session-lines: it says which Work Card passes ran without being shown in Orca.

@Suite("Night Summary: Passes not shown in Orca")
struct NightSummaryPassesNotShownInOrcaTests {
    @Test("Each Card and pass renders one line in first-seen order, a repeated pass once")
    func eachCardAndPassRendersOneLine() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        _ = try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            work: { context in
                // Card 1 records event in architect pass and worker pass
                try journal.append(
                    .agentPassNotShownInOrca(
                        cardID: 1, issueID: "ENG-1", attemptID: 1, pass: .architect, cli: "claude",
                        reason: "Orca unreachable"
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
                try journal.append(
                    .agentPassNotShownInOrca(
                        cardID: 1, issueID: "ENG-1", attemptID: 1, pass: .worker, cli: "claude",
                        reason: "Orca unreachable"
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
                // Card 1's worker pass runs unseen again in a later Round
                try journal.append(
                    .agentPassNotShownInOrca(
                        cardID: 1, issueID: "ENG-1", attemptID: 1, pass: .worker, cli: "claude",
                        reason: "Orca unreachable"
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
                // Card 2 records event in worker pass
                try journal.append(
                    .agentPassNotShownInOrca(
                        cardID: 2, issueID: "ENG-4", attemptID: 1, pass: .worker, cli: "codex",
                        reason: "Orca unreachable"
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
            }
        ).run()
        let opened = try #require(try journal.currentNight())

        let lines = try NightSummary.passesNotShownInOrcaLines(night: opened, journal: journal)

        #expect(lines == [
            "`ENG-1` · architect: not shown in Orca (Orca unreachable)",
            "`ENG-1` · worker: not shown in Orca (Orca unreachable)",
            "`ENG-4` · worker: not shown in Orca (Orca unreachable)"
        ])
    }

    @Test("A Night with no passes not shown in Orca events renders no lines")
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

        let lines = try NightSummary.passesNotShownInOrcaLines(night: night, journal: journal)

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

        let withNotShown = NightCardBlock.completed(
            night: night, projectID: journal.projectID,
            passesNotShownInOrca: ["`ENG-1` · worker: not shown in Orca (Orca unreachable)"]
        )
        #expect(withNotShown.contains("**Passes not shown in Orca:**"))
        #expect(withNotShown.contains("- `ENG-1` · worker: not shown in Orca (Orca unreachable)"))

        let withoutNotShown = NightCardBlock.completed(night: night, projectID: journal.projectID)
        #expect(!withoutNotShown.contains("**Passes not shown in Orca:**"))
    }
}
