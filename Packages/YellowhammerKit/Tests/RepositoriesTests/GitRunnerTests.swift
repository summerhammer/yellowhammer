import Foundation
import Repositories
import Testing

@Suite("GitRunner tests")
struct GitRunnerTests {
    @Test("Git runner executes commands and returns stdout")
    func gitRunnerExecutesCommand() async {
        let runner = GitRunner()
        let result = await runner.run(["--version"])
        #expect(result.isSuccess)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("git version"))
        #expect(result.stderr.isEmpty)
    }

    @Test("Git runner captures failures and stderr on non-zero exit")
    func gitRunnerCapturesFailure() async {
        let runner = GitRunner()
        let result = await runner.run(["nonexistent-subcommand-xyz"])
        #expect(!result.isSuccess)
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("is not a git command"))
    }

    @Test("Git runner terminates process on timeout")
    func gitRunnerTerminatesOnTimeout() async {
        let runner = GitRunner(executablePath: "/bin/sleep")
        let result = await runner.run(["5"], timeout: 0.2)
        #expect(!result.isSuccess)
        #expect(result.exitCode == 124)
        #expect(result.stderr.contains("timed out"))
    }

    @Test("Git runner returns complete output far larger than a pipe buffer")
    func gitRunnerDrainsLargeOutput() async {
        // 256 KiB on stdout and 128 KiB on stderr, well past the 64 KiB pipe buffer a sequential drain deadlocks on.
        let runner = GitRunner(executablePath: "/bin/sh")
        let script = "head -c 262144 /dev/zero | tr '\\0' 'a'; head -c 131072 /dev/zero | tr '\\0' 'b' >&2"
        let result = await runner.run(["-c", script])
        #expect(result.isSuccess)
        #expect(result.stdout.utf8.count == 262_144)
        #expect(result.stderr.utf8.count == 131_072)
    }

    @Test("Cancelling the calling task tears git down and returns promptly")
    func gitRunnerIsCancellable() async {
        let runner = GitRunner(executablePath: "/bin/sleep")
        let clock = ContinuousClock()
        let task = Task { await runner.run(["30"]) }
        try? await Task.sleep(for: .milliseconds(200))
        let elapsed = await clock.measure {
            task.cancel()
            _ = await task.value
        }
        let result = await task.value
        #expect(elapsed < .seconds(5))
        #expect(!result.isSuccess)
        #expect(result.exitCode != 124)
    }
}
