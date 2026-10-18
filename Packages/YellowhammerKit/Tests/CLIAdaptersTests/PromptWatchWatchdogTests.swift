@testable import CLIAdapters
import Darwin
import Foundation
import Testing

// #579: a pass's `log stream` must not outlive `yh` when `yh` dies without running Swift code. The watchdog
// that wraps the stream is tested against real processes, with `sleep` standing in for `yh` and for `log`.
@Suite("Prompt watch watchdog", .timeLimit(.minutes(1)))
struct PromptWatchWatchdogTests {
    private func spawnWatchdog(watching watched: pid_t, output: URL) throws -> pid_t {
        let spawned = ProcessGroup.spawn(
            executable: "/bin/sh",
            arguments: ["-c", PromptWatch.watchdogScript, "sh", String(watched), output.path, "/bin/sleep", "300"],
            environment: ProcessInfo.processInfo.environment,
            worktreePath: "/",
            outputPath: nil
        )
        guard case .success(let pid) = spawned else { throw SpawnFailure() }
        return pid
    }

    private struct SpawnFailure: Error {}

    private func waitUntil(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test("SIGKILLing the watched process takes the stream and its file down within seconds")
    func streamDiesWithWatchedProcess() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-prompt-watch-test-\(UUID().uuidString).ndjson")
        #expect(FileManager.default.createFile(atPath: output.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: output) }

        guard case .success(let watched) = ProcessGroup.spawn(
            executable: "/bin/sleep", arguments: ["300"], environment: [:], worktreePath: "/", outputPath: nil
        ) else { throw SpawnFailure() }
        let watchdog = try spawnWatchdog(watching: watched, output: output)
        defer {
            ProcessGroup.signal(group: watchdog, SIGKILL)
            kill(watched, SIGKILL)
            ProcessGroup.reapBlocking(pid: watchdog)
            ProcessGroup.reapBlocking(pid: watched)
        }

        // Still running while the watched process lives.
        try await Task.sleep(for: .milliseconds(1500))
        #expect(ProcessGroup.isAlive(group: watchdog))
        #expect(FileManager.default.fileExists(atPath: output.path))

        kill(watched, SIGKILL)
        ProcessGroup.reapBlocking(pid: watched)

        let gone = await waitUntil(timeout: .seconds(15)) {
            _ = ProcessGroup.reapNonBlocking(pid: watchdog)
            return !ProcessGroup.isAlive(group: watchdog)
        }
        #expect(gone, "the stream outlived the watched process")
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
