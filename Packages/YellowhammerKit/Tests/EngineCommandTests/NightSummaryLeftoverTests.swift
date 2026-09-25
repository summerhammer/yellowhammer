import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// Normal-Exit Sweep Ruling (issue #175): the Night Summary's `**Leftover processes:**` section,
// mirroring NightSummaryExceptionsTests' `**Crashes and reclaims:**` coverage.

@Suite("Night Summary: Leftover processes (issue #175)")
struct NightSummaryLeftoverTests {
    @Test("Two Cards' leftover events render as one line of distinct swept and unattributed counts per Card")
    func twoCardsRenderOneLine() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        _ = try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            work: { context in
                try journal.append(
                    .leftoverProcessRecorded(
                        cardID: 1, issueID: "ENG-1", attemptID: 1, pass: .worker, pid: 100, commandName: "node",
                        disposition: .sweptByRunningSnapshot, cwd: nil
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
                try journal.append(
                    .leftoverProcessRecorded(
                        cardID: 1, issueID: "ENG-1", attemptID: 1, pass: .worker, pid: 101, commandName: "python3",
                        disposition: .sweptByWorktreeFence, cwd: nil
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
                try journal.append(
                    .leftoverProcessRecorded(
                        cardID: 1, issueID: "ENG-1", attemptID: 1, pass: .worker, pid: 102, commandName: "sleep",
                        disposition: .leftRunningUnattributed, cwd: "/tmp/wt"
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
                // The same unattributed process, still running when the reviewer's pass is fenced: counted once.
                try journal.append(
                    .leftoverProcessRecorded(
                        cardID: 1, issueID: "ENG-1", attemptID: 1, pass: .reviewer, pid: 102, commandName: "sleep",
                        disposition: .leftRunningUnattributed, cwd: "/tmp/wt"
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
                try journal.append(
                    .leftoverProcessRecorded(
                        cardID: 2, issueID: "ENG-4", attemptID: 1, pass: .worker, pid: 200, commandName: "node",
                        disposition: .sweptByRunningSnapshot, cwd: nil
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
            }
        ).run()
        let opened = try #require(try journal.currentNight())

        let lines = try NightSummary.leftoverProcessLines(night: opened, journal: journal)

        #expect(lines == ["`ENG-1` 2 swept, 1 left running unattributed; `ENG-4` 1 swept"])
    }

    @Test("A Night with no leftover process events renders no lines")
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

        let lines = try NightSummary.leftoverProcessLines(night: night, journal: journal)

        #expect(lines.isEmpty)
    }

    @Test("The rendered completed block contains the Leftover processes section only when non-empty")
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

        let withLeftovers = NightCardBlock.completed(
            night: night, projectID: journal.projectID, leftoverProcesses: ["`ENG-1` 1 swept"]
        )
        #expect(withLeftovers.contains("**Leftover processes:**"))

        let withoutLeftovers = NightCardBlock.completed(night: night, projectID: journal.projectID)
        #expect(!withoutLeftovers.contains("**Leftover processes:**"))
    }
}
