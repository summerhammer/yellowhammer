import CLIAdapters
import Domain
import Foundation
import Testing

/// The Codex adapter writes `schema.json` for the CLI to read; the runner removes it afterwards, so
/// no captured schema outlives the pass (Evidence Lifecycle).
@Suite("CLIRunner removes the launch's scratch files")
struct CLIRunnerScratchFileTests {
    /// A stub codex that records whether `--output-schema` pointed at an existing file while it ran.
    private static func stubScript(in tempDir: URL, exitStatus: Int32) throws -> URL {
        let scriptPath = tempDir.appendingPathComponent("cli-\(UUID().uuidString).sh")
        let body = """
            #!/bin/sh
            schema=""
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "--output-schema" ]; then schema="$2"; fi
                shift
            done
            if [ -f "$schema" ]; then echo present > '\(tempDir.path)/seen'; fi
            exit \(exitStatus)

            """
        try body.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        return scriptPath
    }

    private func schemaExists(_ fixture: CLIDispatchFixture.Fixture) -> Bool {
        FileManager.default.fileExists(atPath: fixture.runDirectory.appendingPathComponent("schema.json").path)
    }

    private func sawSchema(_ fixture: CLIDispatchFixture.Fixture) -> Bool {
        FileManager.default.fileExists(atPath: fixture.tempDir.appendingPathComponent("seen").path)
    }

    @Test("schema.json exists while a clean-exit stub runs, and is gone after")
    func removedAfterCleanExit() async throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let script = try Self.stubScript(in: fixture.tempDir, exitStatus: 0)

        _ = try await CLIRunner().run(
            fixture.dispatch(cli: "codex", executable: script.path), adapter: CodexAdapter()
        )

        #expect(sawSchema(fixture))
        #expect(!schemaExists(fixture))
    }

    @Test("schema.json is gone after a non-zero exit too")
    func removedAfterNonZeroExit() async throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let script = try Self.stubScript(in: fixture.tempDir, exitStatus: 3)

        let report = try await CLIRunner().run(
            fixture.dispatch(cli: "codex", executable: script.path), adapter: CodexAdapter()
        )

        #expect(report.end == .exited(status: 3))
        #expect(sawSchema(fixture))
        #expect(!schemaExists(fixture))
    }

    @Test("schema.json is gone when the spawn fails after the launch was built")
    func removedAfterSpawnFailure() async throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let script = try Self.stubScript(in: fixture.tempDir, exitStatus: 0)
        // The launch builds (it only needs the run directory), then the missing Worktree refuses the spawn.
        try FileManager.default.removeItem(at: fixture.worktree)

        await #expect(throws: (any Error).self) {
            _ = try await CLIRunner().run(
                fixture.dispatch(cli: "codex", executable: script.path), adapter: CodexAdapter()
            )
        }

        #expect(!sawSchema(fixture))
        #expect(!schemaExists(fixture))
    }
}
