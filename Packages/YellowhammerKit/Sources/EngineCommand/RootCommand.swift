import ArgumentParser
import Config
import Domain
import Engine
import Foundation
import Journal

public struct RootCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "yh",
        abstract: "Yellowhammer Engine: runs one Act for one Project, then exits.",
        subcommands: [AuthorCommand.self, BuildCommand.self, LandCommand.self],
        defaultSubcommand: nil
    )

    public init() { }

    /// Entry point for the `yh` executable, which then needs no ArgumentParser import of its own.
    public static func execute() async {
        await main()
    }
}

protocol ActCommand: AsyncParsableCommand {
    static var act: Act { get }
    var project: String { get }
}

extension ActCommand {
    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(configurationDirectory: URL) async throws {
        let (_, project) = try ProjectResolution.resolve(
            projectArgument: project, configurationDirectory: configurationDirectory
        )
        // The invocation is scoped to the resolved Project: this is the one Journal it is given.
        let journal = try JournalStore.open(configurationDirectory: configurationDirectory, projectID: project.id)
        // Rehearsal is a runtime mode of a Night; the command surface that requests it is P4.1's.
        let invocation = EngineInvocation(act: Self.act, mode: .real, journal: journal)
        try await invocation.run()
    }
}

public struct AuthorCommand: ActCommand {
    public static let configuration = CommandConfiguration(
        commandName: "author",
        abstract: "Run the author Act."
    )
    public static var act: Act { .author }

    @Option(help: "The id of the Project to run the Act for.")
    public var project: String

    public init() { }
}

public struct BuildCommand: ActCommand {
    public static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Run the build Act."
    )
    public static var act: Act { .build }

    @Option(help: "The id of the Project to run the Act for.")
    public var project: String

    public init() { }
}

public struct LandCommand: ActCommand {
    public static let configuration = CommandConfiguration(
        commandName: "land",
        abstract: "Run the land Act."
    )
    public static var act: Act { .land }

    @Option(help: "The id of the Project to run the Act for.")
    public var project: String

    public init() { }
}
