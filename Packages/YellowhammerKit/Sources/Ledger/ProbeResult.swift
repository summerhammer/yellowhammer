import Domain
import Foundation

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
    /// Whether a Round on the same worker can resume its session. Recorded for visibility but does
    /// not gate ``verdict``: it is not one of the three targets a route offering depends on.
    public let findingSessionResumption: ProbeFinding
    /// Whether a read-only pass was kept from the Keychain, Yellowhammer's configuration directory
    /// and Linear (issue #557). Recorded for visibility but does not gate ``verdict``: a gating
    /// finding would silently drop a CLI that cannot be contained from routing.
    public let findingStateContainment: ProbeFinding
    /// The Operator-facing reason a failed CLI is not offered as a route target. Required when
    /// ``verdict`` is failed. May also be non-nil on a passed verdict, to explain a non-gating
    /// finding (``findingSessionResumption``, ``findingStateContainment``) that failed even though the verdict passed — the DB
    /// check constraint already allows that combination.
    public let reason: String?
    /// The diagnostic run whose prompt records this result's dispatches wrote, nil for results
    /// recorded before it existed.
    public let promptRunID: String?

    /// The verdict: passed if the three gating findings are passed, failed if any of them is not.
    /// ``findingSessionResumption`` and ``findingStateContainment`` do not gate this — they are
    /// recorded but never exclude a CLI from routing. Computed from findings so the invariant is unrepresentable in
    /// the wrong state.
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
        findingSessionResumption: ProbeFinding,
        findingStateContainment: ProbeFinding,
        reason: String?,
        promptRunID: String? = nil
    ) {
        self.cli = cli
        self.probedAt = probedAt
        self.adapterVersion = adapterVersion
        self.cliVersion = cliVersion
        self.findingResultFileOnCleanExit = findingResultFileOnCleanExit
        self.findingUnattendedDispatch = findingUnattendedDispatch
        self.findingProcessContainment = findingProcessContainment
        self.findingSessionResumption = findingSessionResumption
        self.findingStateContainment = findingStateContainment
        self.reason = reason
        self.promptRunID = promptRunID
    }
}
