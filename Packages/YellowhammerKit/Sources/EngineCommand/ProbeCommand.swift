import ArgumentParser
import CLIAdapters
import Config
import Domain
import Foundation
import Ledger

/// Probes one agent CLI Adapter and records the Probe Result in the machine-wide Ledger (P7.4:
/// the spec's unattended-dispatch, result-file, process-containment and session-resumption probe
/// targets, plus state containment, issue #557). One probe run serves every Project on the machine.
public struct ProbeCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "probe",
        abstract: "Probe an agent CLI's adapter and record the Probe Result in the Ledger."
    )

    @Argument(
        help: """
            The agent CLI to probe (e.g. `claude`, `codex`, `agy`). \
            When omitted with `--all`, probes every registered CLI.
            """
    )
    public var cli: String?

    @Option(help: "The model to probe with. Every declared CLI Adapter has a default when omitted.")
    public var model: String?

    @Option(help: "The effort to probe with. Every declared CLI Adapter has a default when omitted.")
    public var effort: String?

    @Flag(name: [.customShort("a"), .long], help: "Probe every registered agent CLI adapter.")
    public var all: Bool = false

    @Flag(help: "Keep the probe's scratch work directory even when every finding passed.")
    public var keep: Bool = false

    public init() {}

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(configurationDirectory: URL) async throws {
        let targets: [String]
        if all {
            targets = CLIAdapterRegistry.allNames
        } else if let cli {
            targets = [cli]
        } else {
            throw ValidationError("specify a CLI to probe (e.g. `claude`, `codex`, `agy`) or pass `--all`")
        }

        var anyFailedOrDrifted = false
        for (index, target) in targets.enumerated() {
            if targets.count > 1 {
                if index > 0 { print("") }
                print("=== Probing `\(target)` ===")
            }
            let (verdict, drift) = try await probeTarget(
                cli: target,
                model: (target == self.cli ? self.model : nil),
                effort: (target == self.cli ? self.effort : nil),
                configurationDirectory: configurationDirectory
            )
            if verdict == .failed || drift != nil {
                anyFailedOrDrifted = true
            }
        }

        if anyFailedOrDrifted {
            throw ExitCode(1)
        }
    }

    private func probeTarget(
        cli: String,
        model: String?,
        effort: String?,
        configurationDirectory: URL
    ) async throws -> (verdict: ProbeVerdict, drift: ProbeDrift?) {
        guard let adapter = CLIAdapterRegistry.adapter(named: cli) else {
            throw ValidationError("no CLI Adapter for `\(cli)`")
        }
        let route = try Self.resolveRoute(cli: cli, model: model, effort: effort)
        let executable = try Self.resolveExecutable(cli: cli, configurationDirectory: configurationDirectory)

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-probe-\(cli)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let store = try LedgerStore.open(configurationDirectory: configurationDirectory)
        let previous = try store.latestProbeResult(cli: cli)

        let report = await CLIProbe().run(
            adapter: adapter,
            route: route,
            executable: executable,
            environment: ProcessInfo.processInfo.environment,
            workDirectory: workDirectory,
            protectedDirectories: CLIAdapterDispatch.protectedDirectories(
                configurationDirectory: configurationDirectory
            )
        )

        let probeResult = ProbeRecording.probeResult(
            cli: report.cli,
            probedAt: Date(),
            adapterVersion: report.adapterVersion,
            cliVersion: report.cliVersion,
            unattendedDispatch: report.unattendedDispatch,
            resultFileOnCleanExit: report.resultFileOnCleanExit,
            processContainment: report.processContainment,
            sessionResumption: report.sessionResumption,
            stateContainment: report.stateContainment,
            reason: report.reason
        )
        let recorded = try store.record(probeResult)
        let drift = previous.flatMap { recorded.drift(since: $0) }

        if Self.everyFindingPassed(recorded), !keep {
            try? FileManager.default.removeItem(at: workDirectory)
        } else {
            print("probe work directory kept at \(workDirectory.path)")
        }

        Self.printReport(recorded, drift: drift)

        let eligibility = try store.routeTargetEligibility(cli: cli)
        switch eligibility {
        case .offered:
            print("offered as a route target")
        case .excluded(let reason):
            print("excluded from routing: \(reason)")
        }

        return (recorded.verdict, drift)
    }

    // MARK: - Reporting

    /// Whether the scratch work directory can go: every finding passed, the non-gating ones included,
    /// so a run worth investigating always keeps its evidence.
    static func everyFindingPassed(_ recorded: ProbeResult) -> Bool {
        ProbeTarget.allCases.allSatisfy { recorded.finding(for: $0) == .passed }
    }

    private static func printReport(_ recorded: ProbeResult, drift: ProbeDrift?) {
        for line in reportLines(recorded, drift: drift) {
            print(line)
        }
    }

    /// What `yh probe` prints for one recorded Probe Result, line by line.
    static func reportLines(_ recorded: ProbeResult, drift: ProbeDrift?) -> [String] {
        var lines = [
            "cli: \(recorded.cli)",
            "cli version: \(recorded.cliVersion)",
            "adapter version: \(recorded.adapterVersion)",
            "unattended dispatch: \(recorded.findingUnattendedDispatch.rawValue)",
            "result file on clean exit: \(recorded.findingResultFileOnCleanExit.rawValue)",
            "process containment: \(recorded.findingProcessContainment.rawValue)",
            "session resumption: \(recorded.findingSessionResumption.rawValue)",
            "state containment: \(recorded.findingStateContainment.rawValue)",
            "verdict: \(recorded.verdict.rawValue)"
        ]
        if let reason = recorded.reason {
            lines.append("reason: \(reason)")
        }
        if let drift {
            let targets = drift.regressions.map(\.description).joined(separator: ", ")
            lines.append(
                "drift since the previous probe "
                    + "(\(drift.previousCLIVersion)/\(drift.previousAdapterVersion) -> "
                    + "\(drift.currentCLIVersion)/\(drift.currentAdapterVersion)): \(targets)"
            )
        }
        return lines
    }

    // MARK: - Route

    private static func resolveRoute(cli: String, model: String?, effort: String?) throws -> Route {
        let defaults = defaultRoute(for: cli)
        guard let resolvedModel = model ?? defaults?.model else {
            throw ValidationError("`\(cli)` has no default model; pass --model")
        }
        guard let resolvedEffort = effort ?? defaults?.effort else {
            throw ValidationError("`\(cli)` has no default effort; pass --effort")
        }
        guard let route = Route(cli: cli, model: resolvedModel, effort: resolvedEffort) else {
            throw ValidationError("`--model` and `--effort` must not be empty")
        }
        return route
    }

    /// The default Route probed when `--model`/`--effort` are omitted (spec `routing/add-an-agent-cli`
    /// evidence: a probe should be cheap, so both defaults name a low-cost model and effort).
    private static func defaultRoute(for cli: String) -> (model: String, effort: String)? {
        switch cli {
        case "claude": ("haiku", "low")
        case "codex": ("gpt-5.5", "low")
        case "agy": ("gemini-3.8-flash-low", "low")
        default: nil
        }
    }

    // MARK: - Executable

    private static func resolveExecutable(cli: String, configurationDirectory: URL) throws -> String {
        let machineFile = configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory)
        var declared: String?
        if FileManager.default.fileExists(atPath: machineFile.path(percentEncoded: false)) {
            let machine = try MachineConfiguration.load(contentsOf: machineFile)
            declared = machine.cliAdapters.first { $0.name == cli }?.executable
        }
        guard let executable = ProbeExecutable.resolve(
            name: cli,
            declared: declared,
            path: ProcessInfo.processInfo.environment["PATH"],
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
        ) else {
            throw ValidationError(
                "no executable found for `\(cli)`: declare `executable` under `[cli.\(cli)]` in config.toml, "
                    + "or add `\(cli)` to PATH"
            )
        }
        return executable
    }
}
