#if DEBUG
import Foundation

// The Agent CLIs pane as the prototypes show it: plain values mirroring `ProbeResult` in `Ledger` and
// `ProbeFinding` in `Domain`, which this package does not link. A Probe's stages are `CLIProbe.run`'s, in
// its order; their durations are guesses at a typical run, for the simulated Probe and its estimate only.

/// What one probe target found, as `ProbeFinding` has it.
enum ProbeFinding: String, Hashable {
    case passed
    case failed
    case notRun = "not run"
}

/// The four probe targets a Probe Result records a finding for.
enum ProbeTarget: String, CaseIterable, Identifiable, Hashable {
    case unattendedDispatch
    case resultFileOnCleanExit
    case processContainment
    case sessionResumption

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unattendedDispatch: "Unattended dispatch"
        case .resultFileOnCleanExit: "Result file on clean exit"
        case .processContainment: "Process containment"
        case .sessionResumption: "Session resumption"
        }
    }

    var shortTitle: String {
        switch self {
        case .unattendedDispatch: "Unattended"
        case .resultFileOnCleanExit: "Result file"
        case .processContainment: "Containment"
        case .sessionResumption: "Resumption"
        }
    }

    /// What passing means, in a line.
    var meaning: String {
        switch self {
        case .unattendedDispatch: "Runs to the end with no sign-in or permission prompt"
        case .resultFileOnCleanExit: "Writes its schema-forced result file when it exits cleanly"
        case .processContainment: "Leaves nothing it spawned running after SIGTERM or SIGKILL"
        case .sessionResumption: "Resumes the same session for a new Round"
        }
    }

    /// Session resumption is recorded but never decides the verdict.
    var gatesVerdict: Bool { self != .sessionResumption }
}

/// One Probe Result: a Ledger row.
struct ProbeResultFixture: Hashable {
    var probedAt: Date
    var cliVersion: String
    var adapterVersion: String
    var findings: [ProbeTarget: ProbeFinding]
    var reason: String?

    func finding(_ target: ProbeTarget) -> ProbeFinding { findings[target] ?? .notRun }

    /// Passed when every gating target passed, as `ProbeResult.verdict` computes it.
    var passed: Bool { ProbeTarget.allCases.filter(\.gatesVerdict).allSatisfy { finding($0) == .passed } }

    var failedTargets: [ProbeTarget] { ProbeTarget.allCases.filter { finding($0) != .passed } }

    /// The targets that passed in `previous` and no longer do: `ProbeDrift.regressions`.
    func regressions(since previous: ProbeResultFixture) -> [ProbeTarget] {
        ProbeTarget.allCases.filter { previous.finding($0) == .passed && finding($0) != .passed }
    }

    static func allPassed(_ cliVersion: String, at probedAt: Date) -> ProbeResultFixture {
        ProbeResultFixture(
            probedAt: probedAt, cliVersion: cliVersion, adapterVersion: "1",
            findings: Dictionary(uniqueKeysWithValues: ProbeTarget.allCases.map { ($0, .passed) }), reason: nil
        )
    }
}

/// Whether a declared CLI is offered as a route target, as `RouteTargetEligibility` reads it.
enum CLIEligibility: Hashable {
    case offered
    case excluded(String)
}

/// A declared agent CLI: its `[cli.<name>]` entry joined with its Ledger history.
struct DeclaredCLI: Identifiable, Hashable {
    let name: String
    /// The declared `executable`, `""` when `yh` looks it up on PATH.
    var executable: String
    /// What PATH resolves the name to, when nothing is declared.
    var resolvedExecutable: String
    var latest: ProbeResultFixture?
    var previous: ProbeResultFixture?
    /// Whether a base route names it, so removing it waits on the Base Routing Table.
    var isRouted: Bool
    /// What its next Probe finds: the simulated Probe's script.
    var nextProbe: ProbeResultFixture
    /// How much slower than the typical durations its Probe runs.
    var pace: Double = 1

    var id: String { name }

    var drift: [ProbeTarget] {
        guard let latest, let previous else { return [] }
        return latest.regressions(since: previous)
    }

    var eligibility: CLIEligibility {
        guard let latest else { return .excluded("never probed") }
        if latest.passed { return .offered }
        let failed = latest.failedTargets.filter(\.gatesVerdict).map { $0.title.lowercased() }
        return .excluded("failed \(failed.formatted(.list(type: .and)))")
    }

    var executableText: String { executable.isEmpty ? resolvedExecutable : executable }
}

/// A Probe's stages, in `CLIProbe.run`'s order.
enum ProbeStage: Int, CaseIterable, Identifiable, Comparable {
    case setUp
    case version
    case dispatch
    case resumption
    case sigterm
    case sigkill
    case record

    var id: Int { rawValue }

    static func < (lhs: ProbeStage, rhs: ProbeStage) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .setUp: "Prepare a scratch worktree"
        case .version: "Read the CLI version"
        case .dispatch: "Dispatch unattended"
        case .resumption: "Resume the session"
        case .sigterm: "Stop with SIGTERM"
        case .sigkill: "Stop with SIGKILL"
        case .record: "Record the Probe Result"
        }
    }

    var activeTitle: String {
        switch self {
        case .setUp: "Preparing a scratch worktree"
        case .version: "Reading the CLI version"
        case .dispatch: "Dispatching unattended"
        case .resumption: "Resuming the session"
        case .sigterm: "Stopping with SIGTERM"
        case .sigkill: "Stopping with SIGKILL"
        case .record: "Recording the Probe Result"
        }
    }

    /// What the stage does, for the Operator who wonders why it takes this long.
    func detail(cli: String) -> String {
        switch self {
        case .setUp:
            "A throwaway git worktree in a temporary folder, so nothing \(cli) does touches a Repo."
        case .version:
            "Runs \(cli) --version; the next Probe compares it to spot drift."
        case .dispatch:
            "A real dispatch on the Probe\u{2019}s cheap default route. It must finish with no prompt and "
                + "leave its result file."
        case .resumption:
            "A second dispatch resumes the first one\u{2019}s session and must recall the word it was given."
        case .sigterm:
            "A dispatch that starts a long-running child is stopped with SIGTERM; nothing may outlive the "
                + "3-second grace."
        case .sigkill:
            "The same again, stopped with SIGKILL; nothing may be left running."
        case .record:
            "Writes the Probe Result to this Mac\u{2019}s Ledger, which every Project reads."
        }
    }

    /// The targets whose finding is known once this stage ends.
    var decides: [ProbeTarget] {
        switch self {
        case .dispatch: [.unattendedDispatch, .resultFileOnCleanExit]
        case .resumption: [.sessionResumption]
        case .sigkill: [.processContainment]
        default: []
        }
    }

    /// The stage that decides `target`.
    static func deciding(_ target: ProbeTarget) -> ProbeStage {
        allCases.first { $0.decides.contains(target) } ?? .record
    }

    /// A typical run's duration, in seconds.
    var typicalSeconds: Double {
        switch self {
        case .setUp: 2
        case .version: 1
        case .dispatch: 40
        case .resumption: 30
        case .sigterm: 20
        case .sigkill: 15
        case .record: 1
        }
    }

    static var typicalTotal: Double { allCases.map(\.typicalSeconds).reduce(0, +) }

    /// The lines `yh probe` would print as the stage starts and ends. It prints none today until the Probe
    /// is over; the prototypes assume it reports each stage as it goes.
    func logLines(cli: String, outcome: ProbeResultFixture, starting: Bool) -> [String] {
        starting ? [startLine(cli: cli)] : endLines(outcome: outcome)
    }

    private func startLine(cli: String) -> String {
        let step = "stage \(rawValue + 1)/\(Self.allCases.count)"
        return switch self {
        case .setUp: "\(step): scratch worktree at $TMPDIR/yh-probe-\(cli)-7F3A\u{2026}/worktree"
        case .version: "\(step): \(cli) --version"
        case .dispatch: "\(step): dispatch A, unattended, on the default route"
        case .resumption: "\(step): dispatch B, resuming dispatch A\u{2019}s session"
        case .sigterm: "\(step): containment, SIGTERM after a 3 s grace"
        case .sigkill: "\(step): containment, SIGKILL"
        case .record: "\(step): recording the Probe Result in the Ledger"
        }
    }

    private func endLines(outcome: ProbeResultFixture) -> [String] {
        let failed = outcome.failedTargets
        switch self {
        case .setUp:
            return []
        case .version:
            return ["cli version: \(outcome.cliVersion)"]
        case .dispatch:
            return [failed.contains(.unattendedDispatch)
                ? "dispatch A: stopped at a permission prompt" : "dispatch A: exited 0; result file arrived"]
        case .resumption:
            return [failed.contains(.sessionResumption)
                ? "dispatch B: the resumed session did not recall the word"
                : "dispatch B: exited 0; the resumed session recalled the word"]
        case .sigterm:
            return [failed.contains(.processContainment)
                ? "containment (sigterm): 1 process still running: node (pid 48213)"
                : "containment (sigterm): nothing left running"]
        case .sigkill:
            return ["containment (sigkill): nothing left running"]
        case .record:
            return ["verdict: \(outcome.passed ? "passed" : "failed")"]
                + (outcome.reason.map { ["reason: \($0)"] } ?? [])
                + [outcome.passed ? "offered as a route target" : "excluded from routing"]
        }
    }
}

/// A Probe already under way when a scenario opens, and how far it has got.
struct RunningProbe {
    let cli: String
    let stage: ProbeStage
    let stageElapsed: Double
}

/// What the pane opens on.
enum AgentCLIScenario: String, CaseIterable, Identifiable {
    case allPassed = "Two CLIs, both passed"
    case probing = "Probing claude"
    case trouble = "Failed, drifted, never probed"
    case firstRun = "Nothing declared"

    var id: String { rawValue }

    private static func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        DateComponents(calendar: .current, year: 2026, month: 10, day: day, hour: hour, minute: minute).date ?? .now
    }

    private static var claude: DeclaredCLI {
        DeclaredCLI(
            name: "claude", executable: "", resolvedExecutable: "/opt/homebrew/bin/claude",
            latest: .allPassed("2.1.289 (Claude Code)", at: date(4, 10, 6)),
            previous: .allPassed("2.1.270 (Claude Code)", at: date(28, 9, 12)),
            isRouted: true,
            nextProbe: .allPassed("2.1.289 (Claude Code)", at: .now)
        )
    }

    private static var codex: DeclaredCLI {
        DeclaredCLI(
            name: "codex", executable: "/usr/local/bin/codex", resolvedExecutable: "",
            latest: .allPassed("codex-cli 0.158.0", at: date(4, 10, 7)),
            previous: nil,
            isRouted: false,
            nextProbe: .allPassed("codex-cli 0.158.0", at: .now),
            pace: 1.3
        )
    }

    private static var containmentFailure: ProbeResultFixture {
        var result = ProbeResultFixture.allPassed("codex-cli 0.159.1", at: date(4, 9, 41))
        result.findings[.processContainment] = .failed
        result.reason = "containment (sigterm): node (pid 48213) outlived the process group"
        return result
    }

    private static var agy: DeclaredCLI {
        var outcome = ProbeResultFixture.allPassed("agy 1.4.2", at: .now)
        outcome.findings[.sessionResumption] = .failed
        outcome.reason = "dispatch B: the resumed session did not recall the word"
        return DeclaredCLI(
            name: "agy", executable: "", resolvedExecutable: "/opt/homebrew/bin/agy",
            latest: nil, previous: nil, isRouted: false, nextProbe: outcome, pace: 0.8
        )
    }

    var clis: [DeclaredCLI] {
        switch self {
        case .allPassed, .probing:
            return [Self.claude, Self.codex]
        case .trouble:
            var codex = Self.codex
            codex.previous = codex.latest
            codex.latest = Self.containmentFailure
            codex.nextProbe = Self.containmentFailure
            codex.isRouted = true
            return [Self.claude, codex, Self.agy]
        case .firstRun:
            return []
        }
    }

    /// The registered CLI Adapters, every one the app can offer to declare.
    static let registered = ["claude", "codex", "agy"]

    /// Whether some base route names a declared CLI.
    var hasRoute: Bool { self != .firstRun }

    /// The Probe already under way when the scenario opens, with how far it has got.
    var runningProbe: RunningProbe? {
        self == .probing ? RunningProbe(cli: "claude", stage: .resumption, stageElapsed: 12) : nil
    }
}
#endif
