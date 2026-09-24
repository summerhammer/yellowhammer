import Domain

/// One `yh doctor`/`yh validate` check, in the fixed order they run.
enum DoctorCheck: String, CaseIterable, Sendable {
    case configuration
    case probes
    case git
    case linear
    case launchd
    case orphans
}

/// One finding's severity. A `failure` is what makes `yh doctor`/`yh validate` exit non-zero; a
/// `warning` never does.
enum DoctorSeverity: Equatable, Sendable {
    case pass
    case warning
    case failure

    /// The tag printed in `[tag]` at the start of a finding's line.
    var tag: String {
        switch self {
        case .pass: "pass"
        case .warning: "warn"
        case .failure: "FAIL"
        }
    }
}

/// One thing `yh doctor`/`yh validate` observed: which check produced it, what it is about, how
/// serious it is, and the Operator-facing message.
struct DoctorFinding: Equatable, Sendable {
    let check: DoctorCheck
    let subject: String
    let severity: DoctorSeverity
    let message: String
    /// The Project this finding is scoped to, or nil when it is machine-scoped.
    let projectID: ProjectID?
}
