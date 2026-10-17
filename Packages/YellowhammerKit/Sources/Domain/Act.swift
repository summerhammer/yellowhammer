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

    /// The log file of this Act for one Project, under `homeDirectory`:
    /// `<home>/Library/Logs/Yellowhammer/<project>.<act>.log`. The one place the format is written, so the
    /// log the generated LaunchAgent writes and the log a disclosure points at cannot disagree. A caller that
    /// renders it into a hashed block passes `"~"`, so no machine path enters the block.
    public func logPath(projectID: ProjectID, homeDirectory: String) -> String {
        "\(homeDirectory)/Library/Logs/Yellowhammer/\(projectID.rawValue).\(rawValue).log"
    }
}
