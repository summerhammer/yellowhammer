import Config
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import GRDB
import Repositories
@testable import Journal
import Testing

struct RemovalDeliverySetup {
    let journal: JournalStore
    let boards: NightCardTestBoards
    let reading: FakeReadingBoard
    let board: ActBoard
    let runID: RunID
    let night: NightRecord
    let outbox: Outbox
    let maintenance: NightCardMaintenance

    init(directory: URL) async throws {
        journal = try JournalStore.openSeeded(
            configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "alpha"))
        )
        boards = try await makeBoards()
        reading = FakeReadingBoard([])
        try await reading.readThrough(boards)
        board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)
        runID = RunID()
        _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: removalEpoch)
        night = try journal.openNight(
            nightStart: removalNightStart, mode: .real, act: .author, runID: runID, now: removalEpoch
        ).night
        outbox = Outbox(journal: journal, board: boards.writing, reading: reading,
            runID: runID, act: .author, clock: { removalEpoch })
        maintenance = NightCardMaintenance(journal: journal, outbox: outbox, provisioning: boards.provisioning)
    }

    func remove(
        directory: URL, home: RemovalHomeFixture, output: RecordingOutput = RecordingOutput(),
        budget: DescriptionBudget? = nil,
        workspace: RemovalFakeWorkspace = RemovalFakeWorkspace(),
        interrupt: @escaping @Sendable (OutboxEntry) throws -> Void = { _ in }
    ) -> ProjectRemoval {
        let writing = boards.writing
        let board = ActBoard(reading: reading, writing: writing, provisioning: boards.provisioning,
            descriptionBudget: budget)
        return ProjectRemoval(
            configurationDirectory: directory, homeDirectory: home.url, output: { output.record($0) },
            console: ScriptedConsole(answers: ["y"]), launchAgents: RecordingLaunchAgentControl(),
            bindBoard: { _, _ in writing }, workspace: workspace, git: GitRunner(),
            bindPush: { _, _ in { _, _, _ in .notPushedInRehearsal } }, now: removalEpoch,
            bindDeliveryBoard: { _, _ in board }, scrub: { .none }, deliveryInterrupt: interrupt
        )
    }

    func release() throws { try journal.releaseActLease(runID: runID) }
}

func removalJournalContents(_ journal: JournalStore) throws -> [String: [String]] {
    try journal.read { db in
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        var result: [String: [String]] = [:]
        for table in tables {
            result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\" ORDER BY rowid")
                .map { $0.description }
        }
        return result
    }
}

func removalTOMLExists(_ directory: URL) -> Bool {
    FileManager.default.fileExists(atPath: directory.appending(components: "projects", "alpha.toml").path)
}
