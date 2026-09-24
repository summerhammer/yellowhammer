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
        subcommands: [
            AuthorCommand.self, BuildCommand.self, LandCommand.self, ProbeCommand.self, SetupCommand.self,
            DoctorCommand.self, ValidateCommand.self, StatusCommand.self, ProjectCommand.self,
            RecalibrateCommand.self, RehearseCommand.self
        ],
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
        bindWorkspace: (() -> any Workspace)?,
        notifier: ExceptionNotifier
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
        bindWorkspace: (() -> any Workspace)? = nil,
        notifier: ExceptionNotifier = .silent
    ) throws -> EngineInvocation {
        let (configuration, project) = try ProjectResolution.resolve(
            projectArgument: project, configurationDirectory: configurationDirectory
        )
        // The invocation is scoped to the resolved Project: this is the one Journal it is given.
        let journal = try JournalStore.open(configurationDirectory: configurationDirectory, projectID: project.id)
        let mode: NightMode = rehearsal ? .rehearsal : .real
        let trigger = try makeTrigger()

        // The land firing at night_end completes the Night; this is decided from the clock against the
        // Project's [schedule], which the generated land LaunchAgent's final firing (night_end plus the
        // Project's stagger offset) satisfies, and a forced land after night_end closes the Night the
        // same way.
        let window = project.schedule.nightWindow(at: now)
        let closesNight = Self.act == .land && now >= window.end

        let board = try bindBoard?(configuration, project)
        let workspace = bindWorkspace?()
        // Built once, here, and carried on every `ActContext` this invocation hands its work (roadmap
        // #114): no consumer threads it through its own initializer any more.
        let operatorIdentity = OperatorIdentity(configured: configuration.machine.operatorIdentity)

        // Every Act wires its own work here, the one place an adapter is constructed for any of them
        // (ADR-001): Engine itself never imports one.
        let work = try Self.work(
            mode: mode, configuration: configuration, project: project,
            configurationDirectory: configurationDirectory
        )
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
            nightCardBounds: NightCardMaintenance.Bounds(
                reviewRoundsMax: project.bounds.reviewRoundsMax,
                attemptsPerCard: project.bounds.attemptsPerCard,
                unansweredNightsMax: project.bounds.unansweredNightsMax,
                reselectionsMax: project.bounds.reselectionsMax,
                consecutiveRefusalsMax: project.bounds.consecutiveRefusalsMax,
                failedAdoptionsMax: project.bounds.failedAdoptionsMax
            ),
            openingReadiness: ReadinessCheck(
                provenance: ProvenanceDiffTester(), citations: MainlineReader()
            ),
            operatorIdentity: operatorIdentity,
            notifier: notifier,
            work: work
        )
    }

    /// This Act's own work. Split out of `makeInvocation` to keep that function within its length limit.
    private static func work(
        mode: NightMode, configuration: Configuration, project: ProjectConfiguration, configurationDirectory: URL
    ) throws -> EngineInvocation.ActWork {
        switch Self.act {
        case .land:
            // The Repo Lane merge test (P10.3) is pure local git and records conflicts without gating
            // landing. Push (P10.2), Verification (P10.5), open pull request (P10.4), returning the
            // Feature (P10.6) and archiving the Cycle (P10.7) are all wired, and run in that order so
            // the pull request body carries the clause report.
            return LandAct(
                mergeTest: FeatureBranchLaneMergeTest(),
                push: LandBinding.push(configuration: configuration, project: project),
                openPullRequest: LandBinding.pullRequest(configuration: configuration, project: project),
                verification: try LandBinding.verification(
                    mode: mode, configuration: configuration, project: project,
                    configurationDirectory: configurationDirectory
                ),
                returnFeature: FeatureReturn(),
                archiveCycle: CycleArchive()
            ).work
        case .author:
            // Selection and breakdown are agent CLI dispatches routed through the ordinary Routing Table
            // under the reserved authoring Kind (P9.11); `AuthoringBinding` wires both, and a Rehearsal
            // Night answers them from the shipped result fixtures. The closure seam (P10.8) is wired to
            // the real `FeatureMergeClosure`: a fully-merged predecessor or in-flight landed Feature is
            // closed unverified, not just observed. The settle seam (P10.9) is wired to the real
            // `FeatureSettleGesture`, applied to whatever Feature the merge closure left in flight.
            return AuthorAct(
                predecessorGate: PredecessorAncestryGate(closure: FeatureMergeClosure()),
                authoring: try AuthoringBinding.authoring(
                    mode: mode, configuration: configuration, project: project,
                    configurationDirectory: configurationDirectory
                ),
                settle: FeatureSettleGesture(),
                unansweredNightsMax: project.bounds.unansweredNightsMax
            ).work
        case .build:
            let cardRunner = try CardRunBinding.cardRunner(
                mode: mode, configuration: configuration, project: project,
                configurationDirectory: configurationDirectory
            )
            return BuildAct(
                cardRunner: cardRunner,
                readiness: ReadinessCheck(provenance: ProvenanceDiffTester(), citations: MainlineReader()),
                // Bound in both modes (P8.10): a rehearsal Night writes no result files, so this simply
                // finds none, and the lease-reclaim sweep falls to the event log and Crashed-Unknown.
                resultReader: RunDirectoryResultReader(
                    runsDirectory: CLIAdapterDispatch.runsDirectory(
                        configurationDirectory: configurationDirectory, projectID: project.id
                    )
                ),
                unansweredNightsMax: project.bounds.unansweredNightsMax
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
            bindWorkspace: { WorkspaceBinding.workspace() },
            notifier: .headlessApp()
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
