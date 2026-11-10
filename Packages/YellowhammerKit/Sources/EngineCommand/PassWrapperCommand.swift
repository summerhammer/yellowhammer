import ArgumentParser
import CLIAdapters
import Foundation

/// Hidden `yh pass-wrapper <spec path>` subcommand (ADR-007 item 6).
struct PassWrapperCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pass-wrapper",
        abstract: "Run an agent CLI pass as its own session leader.",
        shouldDisplay: false
    )

    @Argument(help: "Path to wrapper-spec.json")
    var specPath: String

    func run() throws {
        let outcome = try PassWrapper.run(specPath: specPath)
        let exitCode = outcome.exitStatus ?? (128 + (outcome.signal ?? 0))
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }
}
