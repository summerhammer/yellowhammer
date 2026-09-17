import Domain
import Foundation

/// The result of running ``CLIProbe`` against one agent CLI Adapter. Never a thrown error — every
/// failure the Probe hits becomes a finding plus a sentence in ``reason``, so a Probe run always
/// completes and the Ledger always gets a row.
public struct ProbeReport: Equatable, Sendable {
    public let cli: String
    public let adapterVersion: String
    public let cliVersion: String
    public let unattendedDispatch: ProbeFinding
    public let resultFileOnCleanExit: ProbeFinding
    public let processContainment: ProbeFinding
    public let sessionResumption: ProbeFinding
    /// Non-nil whenever any finding above is not ``ProbeFinding/passed``: one Operator-facing
    /// sentence per non-passed finding, joined with `"; "`.
    public let reason: String?
    /// The scratch directory the probe ran in (its Worktree, run directories and hold script). The
    /// Probe never removes this itself — the caller decides whether to keep or clean it up.
    public let workDirectory: URL

    public init(
        cli: String,
        adapterVersion: String,
        cliVersion: String,
        unattendedDispatch: ProbeFinding,
        resultFileOnCleanExit: ProbeFinding,
        processContainment: ProbeFinding,
        sessionResumption: ProbeFinding,
        reason: String?,
        workDirectory: URL
    ) {
        self.cli = cli
        self.adapterVersion = adapterVersion
        self.cliVersion = cliVersion
        self.unattendedDispatch = unattendedDispatch
        self.resultFileOnCleanExit = resultFileOnCleanExit
        self.processContainment = processContainment
        self.sessionResumption = sessionResumption
        self.reason = reason
        self.workDirectory = workDirectory
    }
}
