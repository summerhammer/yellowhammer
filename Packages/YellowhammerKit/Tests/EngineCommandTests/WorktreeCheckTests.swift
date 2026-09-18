import Domain
@testable import Engine
import Foundation
import Testing

// The Check runner's mechanics (roadmap P8.5): how an exit status, the output and a cancellation are
// translated. These run trivial shell one-liners in a temporary directory. They are NOT a repository's Check
// in a rehearsal Night, and a green here says nothing about any repository's Check: a fixture green is not a
// green.

@Suite("Worktree Check runner")
struct WorktreeCheckTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-check-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func run(
        _ command: String, in directory: URL, limit: Int = WorktreeCheck.defaultOutputLimit
    ) async throws -> RepositoryCheckResult {
        try await WorktreeCheck(outputLimit: limit).run(
            repository: "backend", check: .command(command), worktreePath: directory.path
        )
    }

    @Test("check none spawns nothing, even where there is no Worktree")
    func declaredNone() async throws {
        let result = try await WorktreeCheck().run(repository: "backend", check: .none, worktreePath: "/nonexistent")

        #expect(result == .declaredNone)
    }

    @Test("Exit status 0 passes")
    func exitZeroPasses() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await run("exit 0", in: directory) == .passed(output: ""))
    }

    @Test("Any other status fails, carrying the status and both streams in the order printed")
    func nonZeroFails() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await run("echo out; echo err >&2; exit 3", in: directory)

        #expect(result == .failed(output: "out\nerr\n", exitStatus: 3))
    }

    @Test("A command that does not exist fails with status 127, and death by a signal fails")
    func notFoundAndSignal() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        guard case .failed(_, let notFound) = try await run("yh-no-such-command-\(UUID().uuidString)", in: directory)
        else {
            Issue.record("expected a failed Check")
            return
        }
        #expect(notFound == 127)
        guard case .failed(_, let signalled) = try await run("kill -9 $$", in: directory) else {
            Issue.record("expected a failed Check")
            return
        }
        #expect(signalled == 128 + 9)
    }

    @Test("The command runs in the Worktree")
    func runsInTheWorktree() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        guard case .passed(let output) = try await run("pwd", in: directory) else {
            Issue.record("expected a passing Check")
            return
        }

        let printed = URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(printed.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)
    }

    @Test("Output beyond the cap keeps the tail behind a marker saying how much was dropped")
    func outputIsCappedToItsTail() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await run("printf 0123456789abcdefghij", in: directory, limit: 5)

        #expect(result == .passed(output: "[… 15 earlier bytes of output dropped]\nfghij"))
    }

    @Test("Output far larger than a pipe buffer does not hang, and keeps only the cap")
    func largeOutputDoesNotDeadlock() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await run("yes | head -c 1048576", in: directory, limit: 1024)

        guard case .passed(let output) = result else {
            Issue.record("expected a passing Check")
            return
        }
        #expect(output.hasPrefix("[… 1047552 earlier bytes of output dropped]\n"))
        #expect(output.utf8.count == "[… 1047552 earlier bytes of output dropped]\n".utf8.count + 1024)
    }

    @Test("A Worktree that is not there is an engine fault, not a failed Check and not a pass")
    func missingWorktreeThrows() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(component: "yh-missing-\(UUID().uuidString)")

        await #expect(throws: WorktreeCheckError.worktreeMissing(repository: "backend", path: missing.path)) {
            try await WorktreeCheck().run(repository: "backend", check: .command("exit 0"), worktreePath: missing.path)
        }
    }

    @Test("Cancelling the task ends a long Check promptly and throws")
    func cancellationTerminatesTheChild() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = ContinuousClock.now

        let task = Task { try await run("exec sleep 30", in: directory) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
