import CLIAdapters
import Domain
import Foundation

/// Builds ``CLIDispatch`` values and their backing temp directories for P7.3 adapter tests. Every
/// call gets its own per-test temp dir so tests never share state or depend on run order.
enum CLIDispatchFixture {
    struct Fixture {
        let tempDir: URL
        let worktree: URL
        let runDirectory: URL

        func dispatch(
            cli: String,
            model: String = "some-model",
            effort: String = "medium",
            pass: RunPass = .worker,
            instruction: String = "do the thing",
            resume: CLISession? = nil,
            additionalReadableDirectories: [String] = [],
            additionalWritableDirectories: [String] = [],
            executable: String = "/usr/bin/true",
            environment: [String: String] = [:]
        ) -> CLIDispatch {
            let route = Route(cli: cli, model: model, effort: effort)!
            return CLIDispatch(
                route: route,
                pass: pass,
                instruction: instruction,
                worktreePath: worktree.path,
                runDirectory: runDirectory,
                timeout: .seconds(5),
                resume: resume,
                additionalReadableDirectories: additionalReadableDirectories,
                additionalWritableDirectories: additionalWritableDirectories,
                executable: executable,
                environment: environment
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    static func make() throws -> Fixture {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("yh-p73-\(UUID().uuidString)")
        let worktree = tempDir.appendingPathComponent("worktree")
        let runDirectory = tempDir.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        // runDirectory is intentionally NOT pre-created: adapters must create it themselves.
        return Fixture(tempDir: tempDir, worktree: worktree, runDirectory: runDirectory)
    }
}
