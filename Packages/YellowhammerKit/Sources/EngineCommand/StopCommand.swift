import ArgumentParser
import Config
import Foundation
import Journal

/// `yh stop`: the Operator's "Stop the engine" for one Project. Opens only that Project's Journal and
/// records the request to abort every running Attempt in it; see ``EngineStop``.
public struct StopCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the engine for one Project: abort every running Attempt in it."
    )

    @Option(help: "The id of the Project to stop. Required: stopping is never defaulted.")
    public var project: String

    @Option(help: "Seconds to wait for the aborted Attempts to end; 0 returns right after recording.")
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
        let stop = EngineStop(projectID: resolved.id, output: { print($0) }, wait: .seconds(max(0, wait)))
        // A Project that never ran has no Journal, and opening one would create it.
        let file = JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: resolved.id)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            stop.reportNothingToStop()
            return
        }
        let journal = try JournalStore.openExisting(
            configurationDirectory: configurationDirectory, projectID: resolved.id
        )
        try await stop.run(journal: journal)
    }
}
