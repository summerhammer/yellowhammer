import Foundation

// The Unmerged Feature Stack U as the Pulse shows it (spec: feature-authoring/select-the-next-feature,
// `#unmerged-feature-stack`): plain values, read from the Journal alone and never cached. U is separate from the
// in-flight Feature: `PulseSnapshot.feature` is strictly the Feature still being built.

/// U, "Awaiting merge": the verified, landed Features with no Observed Merge in at least one repository they pushed.
public struct UnmergedFeatureStack: Equatable, Sendable {
    /// F1…Fm, the bottom of the stack first: exactly the order `JournalStore.unmergedFeatureStack()` returns.
    public var features: [AwaitingMergeFeature]
    /// The Project's `unmerged_features_max` Bound. Nil from a Journal read: the Bound is Config's fact, which
    /// `ProjectSnapshot.read` fills.
    public var unmergedFeaturesMax: Int?

    public static let empty = UnmergedFeatureStack(features: [])

    public var isEmpty: Bool { features.isEmpty }
    public var count: Int { features.count }

    /// True only when the Bound is known and U has reached it, so a further Feature is not authored.
    public var isFull: Bool {
        guard let unmergedFeaturesMax else { return false }
        return count >= unmergedFeaturesMax
    }

    public init(features: [AwaitingMergeFeature], unmergedFeaturesMax: Int? = nil) {
        self.features = features
        self.unmergedFeaturesMax = unmergedFeaturesMax
    }
}

/// One Feature of U: the Feature Issue and its pushed repositories, each with its merge state.
public struct AwaitingMergeFeature: Identifiable, Equatable, Sendable {
    /// The Feature Issue's Linear issue id, as the Journal records it.
    public let id: String
    /// The Feature Issue's readable identifier (e.g. `ENG-10`), recorded for display.
    public var issueIDForDisplay: String?
    /// The Feature Issue's Linear issue; nil until the Delta Read has recorded its identifier and URL.
    public var link: LinearIssueLink?
    /// Whether this Feature's Cycle landed in the Night the Pulse shows.
    public var landedTonight: Bool
    /// N: the repositories the Feature pushed, sorted.
    public var repositories: [AwaitingMergeRepository]

    /// k: the pushed repositories with an Observed Merge.
    public var mergedCount: Int { repositories.count { $0.merged } }
    /// N, the count of pushed repositories.
    public var pushedCount: Int { repositories.count }

    public init(
        id: String,
        issueIDForDisplay: String? = nil,
        link: LinearIssueLink? = nil,
        landedTonight: Bool,
        repositories: [AwaitingMergeRepository]
    ) {
        self.id = id
        self.issueIDForDisplay = issueIDForDisplay
        self.link = link
        self.landedTonight = landedTonight
        self.repositories = repositories
    }
}

/// One pushed repository of a Feature in U.
public struct AwaitingMergeRepository: Identifiable, Equatable, Sendable {
    public var repo: String
    /// Whether an Observed Merge is recorded for the Feature in this repository.
    public var merged: Bool
    /// The Feature Branch recorded for this repository, when one is.
    public var branch: String?
    /// The pull request's chip, from the recorded pull request URL; nil when none is recorded.
    public var pullRequest: PullRequestChip?
    /// The display identifier of the Feature whose landed tip is this Feature's recorded base in this repository;
    /// nil when the base is mainline.
    public var stackedOn: String?

    public var id: String { repo }

    public init(
        repo: String,
        merged: Bool,
        branch: String? = nil,
        pullRequest: PullRequestChip? = nil,
        stackedOn: String? = nil
    ) {
        self.repo = repo
        self.merged = merged
        self.branch = branch
        self.pullRequest = pullRequest
        self.stackedOn = stackedOn
    }
}

/// An author firing that authored nothing because U was full (spec: feature-authoring/select-the-next-feature),
/// as Tonight states it.
public struct StackFullSkip: Equatable, Sendable {
    /// The one wording of this outcome, shared with the Night account.
    public static let headline = "Authored nothing — the unmerged Feature stack is full"

    /// The display identifiers the latest skip named, in its order.
    public var features: [String]
    /// The Bound the latest skip recorded.
    public var unmergedFeaturesMax: Int
    /// When the latest skip was recorded.
    public var at: Date
    /// How many author firings of the Night skipped this way; at least 1.
    public var count: Int

    public init(features: [String], unmergedFeaturesMax: Int, at: Date, count: Int) {
        self.features = features
        self.unmergedFeaturesMax = unmergedFeaturesMax
        self.at = at
        self.count = count
    }
}
