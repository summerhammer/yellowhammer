import ArgumentParser
import Config
import Domain
import Foundation

/// `yh status`: per Project, on demand — last Journal run, `launchd` job state, sleep and wake
/// history, and a diagnosis of a missed Night (sleep, missing or disabled job, pre-initialization
/// crash). No cross-Project verdict (spec risks.md OQ12 / R8 "Surface 3").
public struct StatusCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show each Project's last run, LaunchAgents, sleep history and missed Nights."
    )

    @Option(help: "Only report this Project.")
    public var project: String?

    @Option(help: "How many past Nights to examine for a missed Night.")
    public var nights: Int = 7

    public init() {}

    public func validate() throws {
        guard nights >= 1 else {
            throw ValidationError("--nights must be at least 1")
        }
    }

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(configurationDirectory: URL) async throws {
        let projectFilter = try resolvedProjectFilter()
        let status = Status(
            configurationDirectory: configurationDirectory,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            output: { print($0) },
            launchAgents: LaunchctlLaunchAgentControl(),
            sleepHistory: PmsetSleepHistory(),
            now: Date(),
            calendar: .current,
            projectFilter: projectFilter,
            examinedNights: nights
        )
        let report = await status.run()
        guard !report.machineFileFailed, !report.unknownProject else {
            throw ExitCode(1)
        }
    }

    private func resolvedProjectFilter() throws -> ProjectID? {
        guard let project else { return nil }
        guard let id = ProjectID(rawValue: project) else {
            throw ValidationError("--project \(project) is not a valid Project id")
        }
        return id
    }
}
