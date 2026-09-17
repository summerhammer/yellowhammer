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
