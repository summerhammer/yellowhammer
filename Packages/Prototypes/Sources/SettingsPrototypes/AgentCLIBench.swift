#if DEBUG
import Foundation
import Observation

// The Agent CLIs pane's state for the prototypes, standing in for the app's `AgentCLIModel`: the declared
// CLIs, and a simulated `yh probe` that walks a Probe's stages on a timer, at a speed the Playground sets,
// and writes the scripted Probe Result when it is done. Nothing here runs `yh` or reads the Ledger.

/// A Probe under way, or the last one, kept for its log.
struct ProbeRun: Hashable {
    let cli: String
    var stage: ProbeStage
    /// Seconds into the current stage, and into the whole Probe.
    var stageElapsed: Double = 0
    var elapsed: Double = 0
    /// How long each stage that has ended took.
    var stageTimes: [ProbeStage: Double] = [:]
    /// Each target's finding once the stage that decides it has ended.
    var decided: [ProbeTarget: ProbeFinding] = [:]
    var log: [String] = []
    var isOver = false
    var wasStopped = false
    let outcome: ProbeResultFixture

    /// The stage `stage` has reached for `other`: ended, under way, or still to come.
    func standing(of other: ProbeStage) -> StageStanding {
        if isOver, wasStopped, other >= stage { return .skipped }
        if other < stage || isOver { return .done }
        return other == stage ? .running : .pending
    }

    /// Where `target` stands: its finding once decided, otherwise whether its stage is running.
    func standing(of target: ProbeTarget) -> TargetStanding {
        if let finding = decided[target] { return .decided(finding) }
        if wasStopped { return .decided(.notRun) }
        return ProbeStage.deciding(target) == stage ? .running : .pending
    }

    /// The share of a typical Probe done, kept short of the end of a stage that overruns.
    var fraction: Double {
        if isOver { return 1 }
        let ended = ProbeStage.allCases.filter { $0 < stage }.map(\.typicalSeconds).reduce(0, +)
        let current = min(stageElapsed, stage.typicalSeconds * 0.95)
        return (ended + current) / ProbeStage.typicalTotal
    }

    /// Seconds a typical Probe still needs from here.
    var remaining: Double {
        let later = ProbeStage.allCases.filter { $0 > stage }.map(\.typicalSeconds).reduce(0, +)
        return later + max(stage.typicalSeconds - stageElapsed, 0)
    }

    /// "Step 4 of 7".
    var stepText: String { "Step \(stage.rawValue + 1) of \(ProbeStage.allCases.count)" }

    /// "1:12".
    var elapsedText: String { Self.clock(elapsed) }

    /// "about 1 min left", in words rather than a countdown that jumps when a stage overruns.
    var remainingText: String {
        switch remaining {
        case ..<10: "a few seconds left"
        case ..<60: "under a minute left"
        default: "about \(Int((remaining / 60).rounded())) min left"
        }
    }

    static func clock(_ seconds: Double) -> String {
        Duration.seconds(Int(seconds)).formatted(.time(pattern: .minuteSecond))
    }
}

enum StageStanding: Hashable { case done, running, pending, skipped }

enum TargetStanding: Hashable {
    case decided(ProbeFinding)
    case running
    case pending
}

@Observable
final class AgentCLIBench {
    var clis: [DeclaredCLI]
    var hasRoute: Bool
    /// Whether `config.toml` exists yet: declaring the first CLI creates it.
    var configMissing: Bool
    /// The Probe under way, if any. One runs at a time, as in the app.
    private(set) var run: ProbeRun?
    /// The last Probe that ended, kept for its log until the next one starts.
    private(set) var lastRun: ProbeRun?
    /// Simulated seconds per real second; 0 pauses the Probe.
    var speed: Double
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(scenario: AgentCLIScenario, speed: Double = 10) {
        clis = scenario.clis
        hasRoute = scenario.hasRoute
        configMissing = scenario == .firstRun
        self.speed = speed
        if let running = scenario.runningProbe {
            start(running.cli)
            let pace = clis.first { $0.name == running.cli }?.pace ?? 1
            while let current = run, current.stage < running.stage {
                advance(by: current.stage.typicalSeconds * pace)
            }
            advance(by: running.stageElapsed)
        }
    }

    var isProbing: Bool { run != nil }

    var declarableNames: [String] {
        AgentCLIScenario.registered.filter { name in !clis.contains { $0.name == name } }
    }

    func probe(_ name: String) {
        guard run == nil else { return }
        start(name)
    }

    /// Stops the Probe under way. Nothing is recorded: `yh probe` writes the Probe Result only at the end.
    func stopProbe() {
        guard var stopped = run else { return }
        stopped.isOver = true
        stopped.wasStopped = true
        stopped.log.append("stopped by the Operator; nothing was recorded")
        lastRun = stopped
        run = nil
        ticker?.cancel()
    }

    func dismissLastRun() { lastRun = nil }

    func remove(_ name: String) {
        clis.removeAll { $0.name == name }
        if lastRun?.cli == name { lastRun = nil }
    }

    func declare(_ name: String, executable: String) {
        let path = executable.trimmingCharacters(in: .whitespaces)
        var outcome = ProbeResultFixture.allPassed(name == "agy" ? "agy 1.4.2" : "\(name) 1.0.0", at: .now)
        if name == "agy" { outcome.findings[.sessionResumption] = .failed }
        clis.append(DeclaredCLI(
            name: name, executable: path, resolvedExecutable: "/opt/homebrew/bin/\(name)",
            latest: nil, previous: nil, isRouted: false, nextProbe: outcome
        ))
        configMissing = false
    }

    // MARK: - The simulated Probe

    private func start(_ name: String) {
        guard let cli = clis.first(where: { $0.name == name }) else { return }
        var started = ProbeRun(cli: name, stage: .setUp, outcome: cli.nextProbe)
        started.log = ProbeStage.setUp.logLines(cli: name, outcome: cli.nextProbe, starting: true)
        run = started
        lastRun = nil
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.run != nil else { return }
                self.advance(by: 0.1 * self.speed)
            }
        }
    }

    private func advance(by seconds: Double) {
        guard var current = run, seconds > 0,
              let cli = clis.first(where: { $0.name == current.cli }) else { return }
        current.elapsed += seconds
        current.stageElapsed += seconds
        while current.stageElapsed >= current.stage.typicalSeconds * cli.pace {
            let took = current.stage.typicalSeconds * cli.pace
            current.stageTimes[current.stage] = took
            current.stageElapsed -= took
            current.log += current.stage.logLines(cli: cli.name, outcome: current.outcome, starting: false)
            for target in current.stage.decides { current.decided[target] = current.outcome.finding(target) }
            guard let next = ProbeStage(rawValue: current.stage.rawValue + 1) else {
                finish(current)
                return
            }
            current.stage = next
            current.log += next.logLines(cli: cli.name, outcome: current.outcome, starting: true)
        }
        run = current
    }

    private func finish(_ finished: ProbeRun) {
        var ended = finished
        ended.isOver = true
        ended.stageElapsed = 0
        if let index = clis.firstIndex(where: { $0.name == ended.cli }) {
            var recorded = ended.outcome
            recorded.probedAt = .now
            clis[index].previous = clis[index].latest
            clis[index].latest = recorded
        }
        lastRun = ended
        run = nil
        ticker?.cancel()
    }
}
#endif
