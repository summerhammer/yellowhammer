import ArgumentParser
import Config
import Domain
import Engine
import Foundation

/// `yh rehearse`: runs a Rehearsal Night for one Project — the author, build and land Acts, in that
/// order, each exactly as `yh <act> --project <id> --force --rehearsal` would run it. It never
/// dispatches an agent CLI, never pushes, and never opens a pull request; board writes are real.
///
/// `--night` (rehearsal-only) lets one session run several successive Nights: a Night's identity is the
/// calendar date of its `night_start`, and the Journal keys a Night on (project_id, night_start), so an
/// end-to-end rehearsal suite exercising `unanswered_nights_max` arithmetic or the predecessor-ancestry
/// gate across Nights needs Night 1, Night 2, Night 3 in sequence rather than one Night per wall-clock day.
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

    @Option(name: .customLong("night"), help: nightHelp)
    public var nightOption: String?

    // Not a stored property: `ParsableArguments` synthesizes `Decodable`, which a stored dictionary of
    // non-Decodable `RehearsalResultFixture` values would break. `validate()` has already parsed
    // `resultFixtureOptions` once to catch every refusal case, so re-parsing it here cannot fail.
    public var resultFixtures: [RunPass: RehearsalResultFixture] {
        (try? ResultFixtureOption.parse(resultFixtureOptions)) ?? [:]
    }

    // Not a stored property, for the same reason `resultFixtures` is not: `validate()` has already
    // refused a malformed date, so re-parsing it here cannot fail.
    public var night: NightStart? {
        nightOption.flatMap { NightStart(rawValue: $0) }
    }

    public init() {}

    public func validate() throws {
        _ = try ResultFixtureOption.parse(resultFixtureOptions)
        if let nightOption {
            guard NightStart(rawValue: nightOption) != nil else {
                throw ValidationError("--night `\(nightOption)` must be `YYYY-MM-DD`.")
            }
        }
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
        try await rehearse.run(
            projectID: resolvedProject.id.rawValue, resultFixtures: resultFixtures, night: night
        )
    }
}
