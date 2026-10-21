import Domain
@testable import Engine
import Foundation
import Journal
import Testing

// board-projection/provision-the-board (P22.8): an Act reads its board through the Project's footprint — the
// Board Mapping and the ids its Journal holds — and never adopts a same-name state on its name alone.

private func invocation(
    journal: JournalStore, boards: NightCardTestBoards, mapping: BoardMapping = .empty
) -> EngineInvocation {
    EngineInvocation(
        act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal, trigger: .forced,
        runID: RunID(),
        board: ActBoard(
            reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning,
            mapping: mapping, footprint: journal
        ),
        work: { _ in }
    )
}

private func id(of name: String, on board: FakeProvisioningBoard) async throws -> BoardObjectID {
    try #require(try await board.workflowStates(team: teamID).first { $0.name == name }).id
}

@Suite("Board footprint at the Act's preflight")
struct BoardFootprintPreflightTests {
    @Test("An Act with no persisted ids, mapping or provenance refuses, printing the Board Mapping lines")
    func unprovenSameNameStatesAreARefusal() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let waiting = try await id(of: "Waiting on You", on: boards.provisioning)

        let refusal = await #expect(throws: BoardScopeUnresolved.self) {
            try await invocation(journal: journal, boards: boards).run()
        }

        let steps = try #require(refusal?.steps)
        #expect(steps.contains {
            $0.contains("workflow state `Waiting on You`") && $0.contains("waiting_on_you = \"\(waiting)\"")
        })
        #expect(await boards.writing.createIssueCalls == 0)
        // No state id was recorded for the unproven names (the Card Type labels, found in their group, were).
        #expect(try journal.boardFootprint().allSatisfy { $0.role.isLabel })
    }

    @Test("A Board Mapping lets the Act run, and its ids are recorded as mapped for the next Act")
    func mappingLetsTheActRunAndIsRecorded() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let waiting = try await id(of: "Waiting on You", on: boards.provisioning)
        let blocked = try await id(of: "Blocked", on: boards.provisioning)
        let mapping = BoardMapping(ids: [.waitingOnYou: waiting, .blocked: blocked])

        try await invocation(journal: journal, boards: boards, mapping: mapping).run()

        let recorded = Dictionary(uniqueKeysWithValues: try journal.boardFootprint().map { ($0.role, $0) })
        #expect(recorded[.waitingOnYou]?.objectID == waiting && recorded[.waitingOnYou]?.source == .mapped)
        #expect(recorded[.blocked]?.objectID == blocked && recorded[.blocked]?.source == .mapped)
        // The next Act needs no mapping: it reuses the recorded ids.
        try await invocation(journal: journal, boards: boards).run()
    }
}
