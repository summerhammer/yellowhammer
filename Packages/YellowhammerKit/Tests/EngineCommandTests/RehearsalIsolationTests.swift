import Config
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import GRDB
import Journal
import Synchronization
import Testing

// Rehearsal Context Ruling (OQ149, issue #351): a Rehearsal Night runs against the Project's declared
// rehearsal Linear project and rehearsal Journal, never its real ones, and is refused before any write
// when either is not defined.

/// The Linear project each `bindBoard` call was handed, in call order.
private final class BoundProjects: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ project: String) { storage.withLock { $0.append(project) } }
    var all: [String] { storage.withLock { $0 } }
}

/// Every row of every table, as text: equal dumps mean the Journal was left exactly as it was, every
/// Night, Feature, Cycle, Work Card, Refusal and counter included.
private func dump(_ journal: JournalStore) throws -> [String: [String]] {
    try journal.read { db in
        let tables = try String.fetchAll(
            db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        var rows: [String: [String]] = [:]
        for table in tables {
            rows[table] = try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\" ORDER BY rowid").map(\.description)
        }
        return rows
    }
}

/// 23:00 local today: inside the default 22:00–06:00 Night, before its end, so a land Act does not close it.
private func midNight() throws -> Date {
    let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    var components = today
    components.hour = 23
    return try #require(Calendar.current.date(from: components))
}

private func command(_ act: Act, _ arguments: [String]) throws -> any ActCommand {
    let parsed = try RootCommand.parseAsRoot([act.rawValue, "--project", "alpha"] + arguments)
    return try #require(parsed as? any ActCommand)
}

/// Seeds the real Journal's in-flight Feature, its Cycle, a Work Card already one unanswered Night in,
/// and an open Refusal, all in `nightID`.
private func seedLoopState(_ journal: JournalStore, nightID: Int64) throws {
    try journal.write { db in
        let timestamp = Date().formatted(.iso8601)
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["REAL-1", "selected", timestamp]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)", arguments: [featureID, timestamp]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at,
                              unanswered_nights)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [cycleID, "REAL-2", "backend", "card", 1, CardState.todo.rawValue, 0, timestamp, 1]
        )
    }
    let feature = try #require(FeatureName(rawValue: "Real Feature"))
    _ = try journal.recordRefusal(feature: feature, content: "Not citable.", nightID: nightID)
}

@Suite("Rehearsal Night isolation (OQ149)")
struct RehearsalIsolationTests {
    @Test("A rehearsal Night leaves a Project's open real Night, its loop state and its board untouched")
    func rehearsalNightLeavesTheRealContextUntouched() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha", rehearsal: true)
        let projectID = try #require(ProjectID(rawValue: "alpha"))
        let now = try midNight()
        let bound = BoundProjects()
        let boards = try await makeBoards()
        let bindBoard: (Config.Configuration, ProjectConfiguration) throws -> ActBoard = { _, project in
            bound.append(project.linearProject)
            return ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        }

        // A real Night is open, with a Feature in flight, a Work Card one unanswered Night in and an open Refusal.
        try await command(.build, ["--force"])
            .makeInvocation(configurationDirectory: directory.url, now: now, bindBoard: bindBoard).run()
        let realURL = JournalStore.defaultFileURL(configurationDirectory: directory.url, id: projectID)
        let real = try JournalStore.openReadOnly(at: realURL, projectID: projectID)
        let realNight = try #require(try real.currentNight())
        #expect(realNight.mode == .real)
        try seedLoopState(try JournalStore.openExisting(configurationDirectory: directory.url, projectID: projectID),
                          nightID: realNight.id)
        let before = try dump(real)
        #expect(try real.inFlightFeature() != nil)

        // A whole rehearsal Night, in the same Night window. A failing Act is asserted on only after the
        // isolation checks, so a rehearsal that reached the real Journal is reported as exactly that.
        var rehearsalFailure: (any Error)?
        for act in [Act.author, .build, .land] where rehearsalFailure == nil {
            do {
                try await command(act, ["--force", "--rehearsal"])
                    .makeInvocation(configurationDirectory: directory.url, now: now, bindBoard: bindBoard).run()
            } catch {
                rehearsalFailure = error
            }
        }

        // The real Journal is exactly as it was: its Night still open (never `opened_and_died`), and its
        // Feature, Cycle, Work Card, Refusal, in-flight slot and every counter unchanged.
        #expect(try dump(real) == before)
        #expect(try real.currentNight() == realNight)
        // Every rehearsal Act bound the board to the rehearsal Linear project, never the real one.
        #expect(bound.all == ["alpha", "alpha-rehearsal", "alpha-rehearsal", "alpha-rehearsal"])
        #expect(rehearsalFailure == nil, "\(String(describing: rehearsalFailure))")

        // The rehearsal kept its own Night, in its own Journal at the declared path, under the same Night key.
        let rehearsalURL = directory.rehearsalJournal(id: "alpha")
        let rehearsal = try JournalStore.openReadOnly(at: rehearsalURL, projectID: projectID)
        let rehearsalNights = try rehearsal.nights(mode: .rehearsal)
        #expect(rehearsalNights.count == 1)
        #expect(try rehearsal.nights(mode: .real).isEmpty)
        #expect(rehearsalNights.first?.nightStart == realNight.nightStart)
        #expect(try rehearsal.inFlightFeature() == nil)
        let rehearsalAfterNight = try dump(rehearsal)

        // A real Act afterwards attaches to the real Night, not the rehearsal one, and touches no rehearsal
        // row. An unforced author Act stands idle on the in-flight Work Card, so it dispatches nothing.
        try await command(.author, [])
            .makeInvocation(configurationDirectory: directory.url, now: now, bindBoard: bindBoard).run()
        #expect(try real.nights(mode: .real).map(\.id) == [realNight.id])
        #expect(try real.nights(mode: .rehearsal).isEmpty)
        #expect(try real.currentNight()?.id == realNight.id)
        #expect(try dump(rehearsal) == rehearsalAfterNight)
    }

    @Test(
        "--rehearsal without a rehearsal context is refused before any Journal is opened or board bound",
        arguments: Act.allCases
    )
    func actRehearsalRefusedWithoutContext(_ act: Act) throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let bound = BoundProjects()

        let refusal = #expect(throws: RehearsalUnavailable.self) {
            try command(act, ["--force", "--rehearsal"]).makeInvocation(
                configurationDirectory: directory.url, now: Date(),
                bindBoard: { _, project in
                    bound.append(project.linearProject)
                    throw CancellationError()
                }
            )
        }

        #expect(refusal?.reasons == [.linearProjectNotDefined, .journalNotDefined])
        #expect(refusal?.description.contains("[board.linear] rehearsal_project") == true)
        #expect(refusal?.description.contains("[rehearsal] journal") == true)
        #expect(bound.all.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.url.appending(component: "journals").path))
    }

    @Test("A Project whose rehearsal Journal is its real Journal is refused, naming the Journal")
    func rehearsalJournalEqualToTheRealOneRefused() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let projectID = try #require(ProjectID(rawValue: "alpha"))
        let realJournal = JournalStore.defaultFileURL(configurationDirectory: directory.url, id: projectID)
        try directory.writeProjectFile(id: "alpha", """
            id = "alpha"
            name = "alpha"
            board = { linear = { connection = "acme", project = "alpha", rehearsal_project = "alpha-rehearsal" } }
            code_hosting = { connection = "github" }
            rehearsal = { journal = "\(realJournal.path(percentEncoded: false))" }
            spec_source = "~/Developer/alpha-spec"

            [[repos]]
            name = "backend"
            path = "~/Developer/alpha-backend"
            role = "backend"
            check = "swift test"
            """)

        let refusal = #expect(throws: RehearsalUnavailable.self) {
            try command(.author, ["--rehearsal"]).makeInvocation(configurationDirectory: directory.url, now: Date())
        }

        #expect(refusal?.reasons == [.journalIsTheRealOne])
        #expect(!FileManager.default.fileExists(atPath: realJournal.path))
    }

    @Test("yh rehearse without a rehearsal context is refused before its first Act")
    func rehearseRefusedWithoutContext() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let refusal = await #expect(throws: RehearsalUnavailable.self) {
            try await RehearseCommand.parse(["--project", "alpha"]).run(configurationDirectory: directory.url)
        }

        #expect(refusal?.reasons == [.linearProjectNotDefined, .journalNotDefined])
        #expect(!FileManager.default.fileExists(atPath: directory.url.appending(component: "journals").path))
    }
}
