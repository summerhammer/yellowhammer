import Domain
import Foundation

/// What the predecessor gate tests for one repository: the commit the land Act recorded as pushed, else the
/// Feature Branch name (feature-authoring/select-the-next-feature, #tested-tip).
///
/// The gate always tests the recorded commit — it may have no branch ref left, only the
/// `refs/yellowhammer/landed/<branch>` pin or the object store. The branch name is read only when no commit
/// was recorded (a Feature pushed before commits were recorded). A recorded commit the repository no longer
/// has is never replaced by the branch, so commits added to the pull request on GitHub are not part of the
/// test; it resolves to no commit, which the gate reports as indeterminate. A tip with no commit and no
/// resolvable branch is indeterminate likewise.
public struct TestedTip: Equatable, Sendable {
    public let branch: FeatureBranch?
    public let recordedCommit: String?

    public init(branch: FeatureBranch?, recordedCommit: String? = nil) {
        self.branch = branch
        self.recordedCommit = recordedCommit
    }

    /// The branch name for reports; empty when no Feature Branch is known.
    var branchName: String { branch?.name ?? "" }
}

extension GitRunner {
    /// The commit `recorded` names, when it is a full object name this repository still has; nil otherwise.
    /// A value that is not a hexadecimal object name is never handed to git, so it cannot be read as an option.
    func existingCommit(_ recorded: String?, in path: String) async -> String? {
        guard let recorded, recorded.count == 40 || recorded.count == 64,
              recorded.allSatisfy(\.isHexDigit)
        else { return nil }
        let probe = await run(["-C", path, "rev-parse", "--verify", "--quiet", "\(recorded)^{commit}"])
        guard probe.isSuccess else { return nil }
        let sha = probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }
}
