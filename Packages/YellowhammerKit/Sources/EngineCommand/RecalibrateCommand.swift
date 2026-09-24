import ArgumentParser
import Config
import Foundation

/// `yh recalibrate`: a read-only view of one Project's Bounds and this Night's proximity to each
/// (spec: object-guide Bound). Scoped to exactly one Project, like every `--project` command that
/// reports one Project's findings (spec risks.md OQ12 "Surface 3") — never opens or migrates a Journal.
public struct RecalibrateCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "recalibrate",
        abstract: "Show one Project's Bounds and this Night's proximity to each."
    )

    @Option(help: "The id of the Project to report. Defaults to the sole configured Project.")
    public var project: String?

    @Flag(help: "Print the report as one line of JSON.")
    public var json: Bool = false

    public init() {}

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(configurationDirectory: URL) throws {
        let (_, resolvedProject) = try ProjectResolution.resolveDefaultingToSoleProject(
            projectArgument: project, configurationDirectory: configurationDirectory
        )
        let recalibrate = Recalibrate(configurationDirectory: configurationDirectory, output: { print($0) }, json: json)
        // Any Journal error other than `.missing` (handled inside `Recalibrate.run`, as "no Night
        // recorded") propagates here; `JournalError`'s `CustomStringConvertible` description and exit
        // code 1 come from ArgumentParser's own error mapping, the same as `ProjectResolutionError` above.
        try recalibrate.run(project: resolvedProject)
    }
}
