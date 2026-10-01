import ArgumentParser
import Config
import Foundation
import Journal

/// `yh abort`: the Operator's "Abort Attempt" for one running Attempt of one Project. Opens only that
/// Project's Journal and records the request to abort that one Attempt; see ``AttemptAbort``.
public struct AbortCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "abort",
        abstract: "Abort one running Attempt of one Project."
    )

    @Option(help: "The id of the Project the Attempt belongs to. Required: aborting is never defaulted.")
    public var project: String

    @Option(help: "The Journal id of the Attempt to abort.")
    public var attempt: Int64

    @Option(help: "Seconds to wait for the aborted Attempt to end; 0 returns right after recording.")
    public var wait: Int = 60

    public init() {}

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(configurationDirectory: URL) async throws {
        let (_, resolved) = try ProjectResolution.resolve(
            projectArgument: project, configurationDirectory: configurationDirectory
        )
        let abort = AttemptAbort(
            projectID: resolved.id, attemptID: attempt, output: { print($0) }, wait: .seconds(max(0, wait))
        )
        // A Project that never ran has no Journal, and opening one would create it.
        let file = JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: resolved.id)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            abort.reportNothingToAbort()
            return
        }
        let journal = try JournalStore.open(configurationDirectory: configurationDirectory, projectID: resolved.id)
        try await abort.run(journal: journal)
    }
}
