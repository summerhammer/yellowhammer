import Domain

/// Whether a CLI's latest Probe Result offers it as a route target.
public enum RouteTargetEligibility: Equatable, Sendable {
    /// The CLI's latest Probe Result passed: it may be routed to.
    case offered
    /// The CLI is not offered as a route target, and why (Operator-facing).
    case excluded(reason: String)
}

/// One probe target a Probe Result reports a finding for. Distinct from the three gating findings
/// in ``ProbeResult/verdict`` — ``sessionResumption`` is recorded but never gates routing — this
/// covers every finding a Probe Result can drift on.
public enum ProbeTarget: String, CaseIterable, Sendable {
    case unattendedDispatch
    case resultFileOnCleanExit
    case processContainment
    case sessionResumption
}

extension ProbeTarget: CustomStringConvertible {
    /// Names what drifted, for an Operator-facing drift message.
    public var description: String {
        switch self {
        case .unattendedDispatch:
            "argv (unattended dispatch)"
        case .resultFileOnCleanExit:
            "output format (result file on clean exit)"
        case .sessionResumption:
            "session handling (session resumption)"
        case .processContainment:
            "process containment"
        }
    }
}

/// A regression detected between two Probe Results for the same CLI, derived at read time and
/// never stored: at least one probe target that passed in the earlier result no longer passes.
public struct ProbeDrift: Equatable, Sendable {
    public let previousCLIVersion: String
    public let previousAdapterVersion: String
    public let currentCLIVersion: String
    public let currentAdapterVersion: String
    /// The targets that regressed, in ``ProbeTarget/allCases`` order.
    public let regressions: [ProbeTarget]

    public init(
        previousCLIVersion: String,
        previousAdapterVersion: String,
        currentCLIVersion: String,
        currentAdapterVersion: String,
        regressions: [ProbeTarget]
    ) {
        self.previousCLIVersion = previousCLIVersion
        self.previousAdapterVersion = previousAdapterVersion
        self.currentCLIVersion = currentCLIVersion
        self.currentAdapterVersion = currentAdapterVersion
        self.regressions = regressions
    }
}

extension ProbeResult {
    /// The finding for one probe target.
    public func finding(for target: ProbeTarget) -> ProbeFinding {
        switch target {
        case .unattendedDispatch: findingUnattendedDispatch
        case .resultFileOnCleanExit: findingResultFileOnCleanExit
        case .processContainment: findingProcessContainment
        case .sessionResumption: findingSessionResumption
        }
    }

    /// The drift from `previous` to `self`, or `nil` if nothing regressed. A target regressed when
    /// it was `.passed` in `previous` and is not `.passed` now.
    public func drift(since previous: ProbeResult) -> ProbeDrift? {
        let regressions = ProbeTarget.allCases.filter { target in
            previous.finding(for: target) == .passed && finding(for: target) != .passed
        }
        guard !regressions.isEmpty else { return nil }
        return ProbeDrift(
            previousCLIVersion: previous.cliVersion,
            previousAdapterVersion: previous.adapterVersion,
            currentCLIVersion: cliVersion,
            currentAdapterVersion: adapterVersion,
            regressions: regressions
        )
    }
}
