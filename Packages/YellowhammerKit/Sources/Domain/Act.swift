public enum Act: String, CaseIterable, Sendable {
    case author
    case build
    case land
}

extension Act {
    /// The `launchd` LaunchAgent label of this Act for one Project: `dev.yellowhammer.<project>.<act>`.
    /// The one place the format is written, so the job setup generates and the job the app looks for
    /// cannot disagree.
    public func launchdLabel(projectID: ProjectID) -> String {
        "dev.yellowhammer.\(projectID.rawValue).\(rawValue)"
    }
}
