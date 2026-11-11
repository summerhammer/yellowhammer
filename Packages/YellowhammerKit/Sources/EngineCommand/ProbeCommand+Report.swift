import Domain
import Ledger

extension ProbeCommand {
    // MARK: - Reporting

    /// Whether the scratch work directory can go: every finding passed, the non-gating ones included,
    /// so a run worth investigating always keeps its evidence.
    /// Session naming counts unless it failed: a `not_run` one means the Adapter has no naming flag (every
    /// Codex and Antigravity probe) or the CLI's own transcript was not found, and the work directory holds
    /// nothing that explains either.
    static func everyFindingPassed(_ recorded: ProbeResult) -> Bool {
        recorded.orca.observations.allSatisfy { $0.1.finding == .passed } &&
        ProbeTarget.allCases.allSatisfy { target in
            let finding = recorded.finding(for: target)
            return finding == .passed || (target == .sessionNaming && finding == .notRun)
        }
    }

    static func printReport(_ recorded: ProbeResult, drift: ProbeDrift?) {
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
            "session naming: \(recorded.findingSessionNaming.rawValue)",
            "verdict: \(recorded.verdict.rawValue)"
        ]
        for (label, observation) in recorded.orca.observations {
            let answer = switch observation.finding {
            case .passed: "yes"
            case .failed: "no"
            case .notRun: "unconfirmed"
            }
            lines.append("\(label): \(answer)")
            if let detail = observation.detail { lines.append("  \(detail)") }
        }
        if recorded.orca.observations.contains(where: { $0.1.finding != .passed }) {
            lines.append("unconfirmed Orca capabilities keep the CLI’s known behaviour; routing is unchanged")
        }
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
}
