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
}
