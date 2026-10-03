import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

@testable import Journal

private let productTeam = BoardTeam(id: BoardObjectID(rawValue: "team-2"), key: "PRD", name: "Product")

@Suite("yh setup: a reused Project id and its kept Journal")
struct SetupReusedProjectIDTests {
    private func arguments() -> [String] {
        makeArguments(
            operatorID: "user-op", project: "demo", linearTeam: "ENG",
            specSource: "~/dev/demo-spec", repo: ["backend,backend,~/dev/demo-backend,swift test"]
        )
    }

    private func projectFileExists(_ configurationDirectory: URL, _ id: String = "demo") -> Bool {
        FileManager.default.fileExists(
            atPath: configurationDirectory.appending(components: "projects", "\(id).toml").path(percentEncoded: false)
        )
    }

    private func keepJournal(
        _ configurationDirectory: URL, workspace: String, id: String = "demo"
    ) throws -> URL {
        let projectID = try #require(ProjectID(rawValue: id))
        _ = try JournalStore.open(
            configurationDirectory: configurationDirectory, projectID: projectID,
            linearWorkspace: BoardObjectID(rawValue: workspace)
        )
        return JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: projectID)
    }

    @Test("A kept Journal of another Linear workspace is refused before any Linear project or Project file")
    func differentWorkspaceIsRefused() async throws {
        let directory = ConfigurationDirectory()
        let journalURL = try keepJournal(directory.url, workspace: "workspace-other")
        let before = try Data(contentsOf: journalURL)
        let board = await makeBoard(project: nil)
        let output = RecordingOutput()
        let setup = try makeSetup(arguments: arguments(), directory: directory, board: board, output: output)

        let error = await #expect(throws: SetupError.self) { try await setup.run() }

        let message = try #require(error?.message)
        #expect(message.contains("workspace-other"))
        #expect(message.contains("workspace-1"))
        #expect(message.contains("acme"))
        #expect(message.contains(journalURL.path(percentEncoded: false)))
        #expect(await board.creates == 0)
        #expect(!projectFileExists(directory.url))
        #expect(try Data(contentsOf: journalURL) == before)
    }

    @Test("A kept Journal of the same Linear workspace is reopened untouched and setup proceeds")
    func sameWorkspaceIsReopened() async throws {
        let directory = ConfigurationDirectory()
        let journalURL = try keepJournal(directory.url, workspace: "workspace-1")
        let projectID = try #require(ProjectID(rawValue: "demo"))
        let saltBefore = try JournalStore.openReadOnly(at: journalURL, projectID: projectID).outboxSalt
        let board = await makeBoard(project: nil)
        let output = RecordingOutput()
        let setup = try makeSetup(arguments: arguments(), directory: directory, board: board, output: output)

        try await setup.run()

        #expect(projectFileExists(directory.url))
        let after = try JournalStore.openReadOnly(at: journalURL, projectID: projectID)
        #expect(after.outboxSalt == saltBefore)
        #expect(after.linearWorkspace == BoardObjectID(rawValue: "workspace-1"))
        #expect(output.lines.contains { $0.contains("reopened") })
    }

    @Test("A kept Journal written by an earlier build is refused, and no Project file is written")
    func schemaOneJournalIsRefused() async throws {
        let directory = ConfigurationDirectory()
        let journalURL = try keepJournal(directory.url, workspace: "workspace-1")
        let projectID = try #require(ProjectID(rawValue: "demo"))
        try Self.rewriteAsSchemaOne(journalURL, projectID: projectID)
        let board = await makeBoard(project: nil)
        let setup = try makeSetup(arguments: arguments(), directory: directory, board: board)

        let error = await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(try #require(error?.message).contains("demo"))
        #expect(await board.creates == 0)
        #expect(!projectFileExists(directory.url))
    }

    private static func rewriteAsSchemaOne(_ journalURL: URL, projectID: ProjectID) throws {
        // The writer is gone when this returns, before setup's read-only open.
        let journal = try JournalStore.open(
            at: journalURL, projectID: projectID, linearWorkspace: BoardObjectID(rawValue: "workspace-1")
        )
        try journal.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations")
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('journal-schema-1')")
        }
    }

    @Test("Interactively, a refused Project id re-prompts and a fresh id then succeeds")
    func interactiveRefusalReprompts() async throws {
        let directory = ConfigurationDirectory()
        _ = try keepJournal(directory.url, workspace: "workspace-other")
        let board = await makeBoard(project: nil, teams: [engineeringTeam, productTeam])
        let project = [
            "", // Project name -> default
            "", // Linear project id -> empty creates one
            "2", // Team #2 (Product)
            "~/dev/demo-spec", // Spec Source path
            "backend", "~/dev/demo-backend", "backend", "swift test", // repo name/path/role/check
            "n" // Add another repo?
        ]
        let console = ScriptedConsole(
            answers: ["", "", "", "", "y", "demo"] + project + ["demo2"] + project + ["n"]
        )
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, operatorID: "user-op"), directory: directory,
            board: board, console: console, output: output
        )

        try await setup.run()

        #expect(!projectFileExists(directory.url))
        #expect(projectFileExists(directory.url, "demo2"))
        #expect(output.lines.filter { $0.hasPrefix("created Linear project") }.count == 1)
        #expect(output.lines.contains { $0.contains("workspace-other") })
    }
}
