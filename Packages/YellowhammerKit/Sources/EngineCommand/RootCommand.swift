import ArgumentParser
import Config
import Domain
import Engine
import Foundation
import Journal
import Repositories

public struct RootCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "yh",
        abstract: "Yellowhammer Engine: runs one Act for one Project, then exits.",
        subcommands: [AuthorCommand.self, BuildCommand.self, LandCommand.self, ProbeCommand.self],
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
    func makeInvocation(
        configurationDirectory: URL,
        now: Date,
        bindBoard: ((Configuration, ProjectConfiguration) throws -> ActBoard)?,
        bindWorkspace: (() -> any Workspace)?
    ) throws -> EngineInvocation
}

extension ActCommand {
    func makeTrigger() throws -> ActTrigger {
        force ? .forced : .scheduled
    }

    func makeInvocation(
        configurationDirectory: URL,
        now: Date = Date(),
        bindBoard: ((Configuration, ProjectConfiguration) throws -> ActBoard)? = nil,
        bindWorkspace: (() -> any Workspace)? = nil
    ) throws -> EngineInvocation {
        let (configuration, project) = try ProjectResolution.resolve(
            projectArgument: project, configurationDirectory: configurationDirectory
        )
        // The invocation is scoped to the resolved Project: this is the one Journal it is given.
        let journal = try JournalStore.open(configurationDirectory: configurationDirectory, projectID: project.id)
        let mode: NightMode = rehearsal ? .rehearsal : .real
        let trigger = try makeTrigger()

        // The land firing at night_end completes the Night; before P13.2 generates the LaunchAgents
        // this is decided from the clock against the Project's [schedule], and a forced land after
        // night_end closes the Night the same way.
        let window = project.schedule.nightWindow(at: now)
        let closesNight = Self.act == .land && now >= window.end

        let board = try bindBoard?(configuration, project)
        let workspace = bindWorkspace?()

        // land keeps a no-work invocation until its own phase lands; build and author each wire their
        // own Act's work here, the one place an adapter is constructed for either (ADR-001): Engine
        // itself never imports one.
        guard
            let work = try Self.work(
                mode: mode, configuration: configuration, project: project,
                configurationDirectory: configurationDirectory
            )
        else {
            // land: no phase has landed to wire in yet; this keeps EngineInvocation's own
            // `notImplemented` default.
            return EngineInvocation(
                act: Self.act,
                mode: mode,
                nightStart: window.nightStart,
                journal: journal,
                trigger: trigger,
                closesNight: closesNight,
                board: board,
                repositories: project.repositories,
                workspace: workspace
            )
        }
        return EngineInvocation(
            act: Self.act,
            mode: mode,
            nightStart: window.nightStart,
            journal: journal,
            trigger: trigger,
            closesNight: closesNight,
            board: board,
            repositories: project.repositories,
            workspace: workspace,
            work: work
        )
    }

    /// This Act's own work, when its phase has landed — nil for land, whose own phase has not landed
    /// yet, and for any other Act EngineInvocation's own default already covers with `notImplemented`.
    /// Split out of `makeInvocation` to keep that function within its length limit.
    private static func work(
        mode: NightMode, configuration: Configuration, project: ProjectConfiguration, configurationDirectory: URL
    ) throws -> EngineInvocation.ActWork? {
        switch Self.act {
        case .land:
            return nil
        case .author:
            // Feature selection (P9.3–P9.7) is a later phase; the predecessor-ancestry gate (P9.2) is
            // wired, and this Act still records every quiet Night's reason (P9.1). The closure seam
            // (P10.8) is not wired yet, so a fully-merged predecessor is only observed, never closed.
            return AuthorAct(predecessorGate: PredecessorAncestryGate(), authoring: nil).work
        case .build:
            let cardRunner = try CardRunBinding.cardRunner(
                mode: mode, configuration: configuration, project: project,
                configurationDirectory: configurationDirectory
            )
            return BuildAct(
                cardRunner: cardRunner,
                // Open until P11: the Operator's board identity is not wired anywhere yet; Waiting on
                // You assignment on a Divergence needs it.
                readiness: ReadinessCheck(
                    provenance: ProvenanceDiffTester(), citations: MainlineReader(), operator: nil
                ),
                // Bound in both modes (P8.10): a rehearsal Night writes no result files, so this simply
                // finds none, and the lease-reclaim sweep falls to the event log and Crashed-Unknown.
                resultReader: RunDirectoryResultReader(
                    runsDirectory: CLIAdapterDispatch.runsDirectory(
                        configurationDirectory: configurationDirectory, projectID: project.id
                    )
                )
            ).work
        }
    }

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(configurationDirectory: URL) async throws {
        let invocation = try makeInvocation(
            configurationDirectory: configurationDirectory,
            now: Date(),
            bindBoard: { configuration, project in
                try BoardBinding.actBoard(machine: configuration.machine, project: project)
            },
            bindWorkspace: { WorkspaceBinding.workspace() }
        )
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
