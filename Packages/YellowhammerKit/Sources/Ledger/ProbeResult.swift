import Foundation

/// A finding from one probe target within a single Probe Result.
public enum ProbeFinding: String, Sendable {
    /// The probe target passed.
    case passed
    /// The probe target failed.
    case failed
    /// The probe run did not exercise this target.
    case notRun = "not_run"
}

/// The verdict of a probe run.
public enum ProbeVerdict: String, Sendable {
    /// All probed targets passed.
    case passed
    /// One or more probed targets failed.
    case failed
}

/// A Ledger row: the result of probing one agent CLI adapter against its probe targets.
/// Probe Results accumulate as a history per agent CLI; adapter health is derived at read time
/// from the latest Probe Result, its age, and the Attempt history since (not stored).
public struct ProbeResult: Equatable, Sendable {
    /// The agent CLI adapter's name, matching `Domain.Route.cli`.
    public let cli: String
    /// When the probe run occurred (ISO 8601 UTC to the second).
    public let probedAt: Date
    /// The adapter version observed at probe time.
    public let adapterVersion: String
    /// The CLI version observed at probe time.
    public let cliVersion: String
    /// Whether a schema-forced result file arrives on clean exit.
    public let findingResultFileOnCleanExit: ProbeFinding
    /// Whether the CLI supports unattended dispatch (no interactive auth or permission prompts).
    public let findingUnattendedDispatch: ProbeFinding
    /// Whether the CLI containment under SIGTERM and SIGKILL prevents orphaned processes.
    public let findingProcessContainment: ProbeFinding
    /// If the verdict is failed, the Operator-facing reason a failed CLI is not offered as a route target.
    /// Nullable: passed verdicts have nil. A failed verdict must carry a reason.
    public let reason: String?

    /// The verdict: passed if all findings are passed, failed if any are not.
    /// Computed from findings so the invariant is unrepresentable in the wrong state.
    public var verdict: ProbeVerdict {
        if findingResultFileOnCleanExit == .passed &&
           findingUnattendedDispatch == .passed &&
           findingProcessContainment == .passed {
            return .passed
        } else {
            return .failed
        }
    }

    public init(
        cli: String,
        probedAt: Date,
        adapterVersion: String,
        cliVersion: String,
        findingResultFileOnCleanExit: ProbeFinding,
        findingUnattendedDispatch: ProbeFinding,
        findingProcessContainment: ProbeFinding,
        reason: String?
    ) {
        self.cli = cli
        self.probedAt = probedAt
        self.adapterVersion = adapterVersion
        self.cliVersion = cliVersion
        self.findingResultFileOnCleanExit = findingResultFileOnCleanExit
        self.findingUnattendedDispatch = findingUnattendedDispatch
        self.findingProcessContainment = findingProcessContainment
        self.reason = reason
    }
}
