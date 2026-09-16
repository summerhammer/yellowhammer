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
    var force: Bool { get }
    var rehearsal: Bool { get }
    func makeTrigger() throws -> ActTrigger
    func makeInvocation(configurationDirectory: URL) throws -> EngineInvocation
}

extension ActCommand {
    func makeTrigger() throws -> ActTrigger {
        force ? .forced : .scheduled
    }

    func makeInvocation(configurationDirectory: URL) throws -> EngineInvocation {
        let (_, project) = try ProjectResolution.resolve(
            projectArgument: project, configurationDirectory: configurationDirectory
        )
        // The invocation is scoped to the resolved Project: this is the one Journal it is given.
        let journal = try JournalStore.open(configurationDirectory: configurationDirectory, projectID: project.id)
        let mode: NightMode = rehearsal ? .rehearsal : .real
        let trigger = try makeTrigger()
        return EngineInvocation(act: Self.act, mode: mode, journal: journal, trigger: trigger)
    }

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(configurationDirectory: URL) async throws {
        let invocation = try makeInvocation(configurationDirectory: configurationDirectory)
        try await invocation.run()
    }
}

// The Operator's three gestures are glossary terms (gate G-12), so every Act spells them the same
// way and describes them in the same words.
private let forceHelp: ArgumentHelp = "Run the Act even when its trigger is not met (Force an Act)."
private let rehearsalHelp: ArgumentHelp = """
    Run this Act as part of a Rehearsal Night: the real Acts, but never dispatching an agent CLI, \
    never pushing, and never opening a pull request.
    """
private let featureHelp: ArgumentHelp = """
    Author the Feature named here instead of selecting one (Force authoring). Implies --force.
    """

public struct AuthorCommand: ActCommand {
    public static let configuration = CommandConfiguration(
        commandName: "author",
        abstract: "Run the author Act."
    )
    public static var act: Act { .author }

    @Option(help: "The id of the Project to run the Act for.")
    public var project: String

    @Flag(name: .long, help: forceHelp)
    public var force: Bool = false

    @Flag(name: .long, help: rehearsalHelp)
    public var rehearsal: Bool = false

    @Option(name: .long, help: featureHelp)
    public var feature: String?

    public init() { }

    func makeTrigger() throws -> ActTrigger {
        if let feature = feature {
            guard let featureName = FeatureName(rawValue: feature) else {
                throw ValidationError("Feature name must not be empty or whitespace-only.")
            }
            return .forcedForFeature(featureName)
        }
        return force ? .forced : .scheduled
    }

    public func validate() throws {
        if let feature = feature {
            guard FeatureName(rawValue: feature) != nil else {
                throw ValidationError("Feature name must not be empty or whitespace-only.")
            }
        }
    }
}

public struct BuildCommand: ActCommand {
    public static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Run the build Act."
    )
    public static var act: Act { .build }

    @Option(help: "The id of the Project to run the Act for.")
    public var project: String

    @Flag(name: .long, help: forceHelp)
    public var force: Bool = false

    @Flag(name: .long, help: rehearsalHelp)
    public var rehearsal: Bool = false

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

    @Flag(name: .long, help: forceHelp)
    public var force: Bool = false

    @Flag(name: .long, help: rehearsalHelp)
    public var rehearsal: Bool = false

    public init() { }
}
