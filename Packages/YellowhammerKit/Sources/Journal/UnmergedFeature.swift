import Domain
import Foundation

/// A member of the Unmerged Feature Stack U (spec: feature-authoring/select-the-next-feature,
/// `#unmerged-feature-stack`): an implemented Feature that pushed work in at least one repository where
/// no merge has been observed yet. Read by ``JournalStore/unmergedFeatureStack()``.
public struct UnmergedFeature: Equatable, Sendable {
    public let feature: FeatureRecord
    /// The distinct, sorted repositories the Feature's Cycle touches (`feature_repository`).
    public let touchedRepositories: [String]
    /// N: the touched repositories minus those with a recorded No-Pushed-Branch Outcome — never empty here.
    public let pushedRepositories: [String]
    /// The Feature Branch per pushed repository, from `feature_repository.branch`; a repository with none
    /// recorded is omitted.
    public let branches: [String: FeatureBranch]
    /// The commit the land Act last pushed per pushed repository (`feature_repository.landed_commit`);
    /// a repository with none recorded is omitted.
    public let landedCommits: [String: String]
    /// The pushed repositories with a recorded Observed Merge (`feature_landing`), sorted.
    public let mergedRepositories: [String]
    /// The pushed repositories with no recorded Observed Merge, sorted — never empty here.
    public let unmergedRepositories: [String]
}

/// `effective_base(R)` (spec `#effective-base`) when it is not mainline: the most recent Feature in U that
/// pushed in the repository and has no Observed Merge there. Nil from
/// ``JournalStore/effectiveBase(repository:excludingFeatureID:)`` means the base is mainline.
public struct EffectiveBase: Equatable, Sendable {
    public let featureID: Int64
    public let featureIssueID: String
    public let branch: FeatureBranch
    /// The commit the land Act last pushed for this Feature in the repository; nil when none is recorded.
    public let landedCommit: String?
}

/// One row of `feature_base`: the base a Feature was authored against in one repository, recorded at
/// selection (spec `#effective-base`).
public struct FeatureBaseRecord: Codable, Equatable, Sendable {
    public let repository: String
    /// `refs/yellowhammer/landed/<branch>` when stacked on a Feature in U, else the mainline ref.
    public let baseRef: String
    public let baseCommit: String
    /// The Feature in U this base is stacked on; nil when the base is mainline.
    public let stackedOnFeatureID: Int64?

    public init(repository: String, baseRef: String, baseCommit: String, stackedOnFeatureID: Int64? = nil) {
        self.repository = repository
        self.baseRef = baseRef
        self.baseCommit = baseCommit
        self.stackedOnFeatureID = stackedOnFeatureID
    }
}
