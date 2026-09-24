import ArgumentParser
import Config
import Domain
import Engine
import Foundation

/// `yh rehearse`: runs a Rehearsal Night for one Project — the author, build and land Acts, in that
/// order, each exactly as `yh <act> --project <id> --force --rehearsal` would run it. It never
/// dispatches an agent CLI, never pushes, and never opens a pull request; board writes are real.
public struct RehearseCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "rehearse",
        abstract: "Run a Rehearsal Night for one Project: author, build, land, in order.",
        discussion: """
            Runs the three Acts of a Rehearsal Night for one Project, each Act forced and in Rehearsal \
            mode. A Rehearsal Night never dispatches an agent CLI, never pushes, and never opens a pull \
            request — those three boundaries are the only difference from a real Night. Board writes are \
            real: it does not stub Linear or Worktrees.
            """
    )

    @Option(help: "The id of the Project to rehearse. Defaults to the sole configured Project.")
    public var project: String?

    @Option(name: .customLong("result-fixture"), parsing: .singleValue, help: ResultFixtureOption.help)
    public var resultFixtureOptions: [String] = []

    // Not a stored property: `ParsableArguments` synthesizes `Decodable`, which a stored dictionary of
    // non-Decodable `RehearsalResultFixture` values would break. `validate()` has already parsed
    // `resultFixtureOptions` once to catch every refusal case, so re-parsing it here cannot fail.
    public var resultFixtures: [RunPass: RehearsalResultFixture] {
        (try? ResultFixtureOption.parse(resultFixtureOptions)) ?? [:]
    }

    public init() {}

    public func validate() throws {
        _ = try ResultFixtureOption.parse(resultFixtureOptions)
    }

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(configurationDirectory: URL) async throws {
        let (_, resolvedProject) = try ProjectResolution.resolveDefaultingToSoleProject(
            projectArgument: project, configurationDirectory: configurationDirectory
        )
        let rehearse = Rehearse(configurationDirectory: configurationDirectory, output: { print($0) })
        try await rehearse.run(projectID: resolvedProject.id.rawValue, resultFixtures: resultFixtures)
    }
}
