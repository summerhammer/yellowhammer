import Domain
import Foundation
import OrcaADEAdapter
import Testing

/// Against the real `orca` CLI — the done-condition a stub cannot prove. Opt-in only:
///
///     YH_ORCA_SCRATCH_TESTS=1 swift test --package-path Packages/YellowhammerKit --filter OrcaADEScratchTests
///
/// Creates three temporary git repositories, registers each with Orca ADE, creates one Worktree per
/// repository through the adapter, then removes each Worktree and its registration — cleanup runs
/// even when an assertion fails.
@Suite(
    "Orca ADE scratch workspace (live)",
    .enabled(if: ProcessInfo.processInfo.environment["YH_ORCA_SCRATCH_TESTS"] == "1")
)
struct OrcaADEScratchTests {
    private struct Registration {
        let directory: URL
        let repoID: String
    }

    @Test("Three repositories each get a Worktree named as requested, then are removed and unregistered")
    func liveWorktreeLifecycle() async throws {
        let runner = ProcessOrcaCommandRunner()
        let adapter = OrcaADEAdapter(runner: runner)

        var registrations: [Registration] = []
        var worktreeIDs: [WorktreeID] = []

        do {
            for index in 0..<3 {
                let directory = FileManager.default.temporaryDirectory.appending(
                    component: "yh-orca-scratch-\(UUID().uuidString)-\(index)", directoryHint: .isDirectory
                )
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Self.initGitRepo(at: directory)

                let registerOutput = try await runner.run(["repo", "add", "--path", directory.path, "--json"])
                let repoID = try Self.repositoryID(from: registerOutput)
                registrations.append(Registration(directory: directory, repoID: repoID))

                let name = "yh-scratch-\(UUID().uuidString.prefix(8))"
                let worktree = try await adapter.createWorktree(
                    repositoryPath: directory.path, name: name, baseBranch: nil
                )
                worktreeIDs.append(worktree.id)

                #expect(worktree.branch == name)
                #expect(FileManager.default.fileExists(atPath: worktree.path))
            }
        } catch {
            await Self.cleanUp(adapter: adapter, runner: runner, registrations: registrations, worktreeIDs: worktreeIDs)
            throw error
        }

        await Self.cleanUp(adapter: adapter, runner: runner, registrations: registrations, worktreeIDs: worktreeIDs)
    }

    private static func cleanUp(
        adapter: OrcaADEAdapter,
        runner: ProcessOrcaCommandRunner,
        registrations: [Registration],
        worktreeIDs: [WorktreeID]
    ) async {
        for id in worktreeIDs {
            _ = try? await adapter.removeWorktree(id: id, force: true)
        }
        for registration in registrations {
            _ = try? await runner.run(["project", "setup-delete", "--setup", registration.repoID, "--json"])
            try? FileManager.default.removeItem(at: registration.directory)
        }
    }

    private static func initGitRepo(at directory: URL) throws {
        try runGit(["init", "--initial-branch=main"], in: directory)
        try runGit(["config", "user.name", "Yellowhammer Scratch Test"], in: directory)
        try runGit(["config", "user.email", "scratch@yellowhammer.local"], in: directory)
        try runGit(["config", "commit.gpgsign", "false"], in: directory)
        let fileURL = directory.appendingPathComponent("README.md")
        try "scratch".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "."], in: directory)
        try runGit(["commit", "-m", "initial"], in: directory)
    }

    private static func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    private static func repositoryID(from output: OrcaCommandOutput) throws -> String {
        let data = try #require(output.stdout.data(using: .utf8))
        let payload = try JSONDecoder().decode(RepositoryRegistrationPayload.self, from: data)
        return payload.result.repo.id
    }
}

private struct RepositoryRegistrationPayload: Decodable {
    let result: Result

    struct Result: Decodable {
        let repo: Repo
    }

    struct Repo: Decodable {
        let id: String
    }
}
