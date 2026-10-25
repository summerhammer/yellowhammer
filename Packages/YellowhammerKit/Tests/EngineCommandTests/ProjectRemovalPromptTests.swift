import Config
import Domain
import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

private struct FailingPromptCleaning: DispatchPromptCleaning {
    let error: any Error
    func removeAll(projectID: ProjectID) throws {
        throw error
    }
}

@Suite("Project removal prompt evidence lifecycle")
struct ProjectRemovalPromptTests {
    @Test("Removal deletes the Project's prompt directory")
    func removalDeletesProjectPromptDirectory() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)

        let promptStore = DispatchPromptStore(
            rootDirectory: DispatchPromptStore.rootDirectory(configurationDirectory: directory.url)
        )
        let projectID = try #require(ProjectID(rawValue: "alpha"))
        let scope = DispatchPromptScope.project(projectID)
        let record = DispatchPromptRecord(
            provenance: DispatchProvenance(recordID: "rec-to-remove", family: .worker, projectID: "alpha"),
            route: "claude/opus/high", pass: .worker, dispatchedAt: Date(), defaultVersion: 1,
            projectInstructions: .absent, session: .new, instruction: "hello", outputSchema: nil, launch: .launched
        )
        _ = promptStore.capture(record)

        let promptProjectDir = promptStore.directory(for: scope)
        #expect(FileManager.default.fileExists(atPath: promptProjectDir.path(percentEncoded: false)))

        let removal = makeRemoval(directory: directory, home: home)
        let succeeded = await removal.run(id: "alpha", yes: true)

        #expect(succeeded)
        #expect(!FileManager.default.fileExists(atPath: promptProjectDir.path(percentEncoded: false)))
    }

    @Test("An injected cleanup failure stops removal before TOML is deleted, without touching journaled footprint")
    func injectedCleanupFailureStopsRemoval() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let repo = TestGitRepo(name: "clean-fail")
        await repo.initRepo()
        _ = try await repo.commit()
        _ = await repo.run(["checkout", "-b", removalBranch.name])
        try directory.writeValidProjectFile(id: "alpha", repoPath: repo.path)
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)

        let journal = try JournalStore.openSeeded(
            configurationDirectory: directory.url, projectID: try #require(ProjectID(rawValue: "alpha"))
        )
        let seeded = try await seedRemovableProject(journal, mode: .rehearsal, repo: repo, pushedCommit: nil)

        let board = FakeWritingBoard()
        await board.seed(issue: seeded.featureIssueID, description: nil)
        let workspace = RemovalFakeWorkspace()
        let output = RecordingOutput()

        enum TestCleanupError: Error, CustomStringConvertible {
            case simulatedDiskError
            var description: String { "simulated disk error" }
        }

        let removal = makeRemoval(
            directory: directory, home: home, output: output, board: board, workspace: workspace,
            promptStore: FailingPromptCleaning(error: TestCleanupError.simulatedDiskError)
        )

        let succeeded = await removal.run(id: "alpha", yes: true)

        #expect(!succeeded)
        // TOML must still exist
        #expect(FileManager.default.fileExists(
            atPath: directory.url.appending(components: "projects", "alpha.toml").path(percentEncoded: false)
        ))

        // Output must report failure and retry line
        #expect(output.lines.contains("could not delete recorded prompts for alpha: simulated disk error"))
        #expect(output.lines.contains("removal incomplete; re-run `yh project remove <id>` to retry"))

        // Nothing after it ran: no board comment, no worktree removal, no journal removal event
        let comments = await board.comments
        #expect(comments.isEmpty)
        #expect(workspace.removeCalls.isEmpty)
        #expect(try journal.events(ofType: .projectRemoved).isEmpty)
    }

    @Test("confirmRemoval lists delete its recorded prompts after Act logs")
    func confirmRemovalListingIncludesPrompts() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)

        let output = RecordingOutput()
        let console = ScriptedConsole(answers: ["n"]) // do not confirm
        let removal = makeRemoval(directory: directory, home: home, output: output, console: console)

        let succeeded = await removal.run(id: "alpha", yes: false)
        #expect(!succeeded)

        let actLogsIndex = try #require(output.lines.firstIndex(of: "- delete its 3 Act logs"))
        let promptsIndex = try #require(output.lines.firstIndex(of: "- delete its recorded prompts"))
        #expect(promptsIndex == actLogsIndex + 1)
    }
}
