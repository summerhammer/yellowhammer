/// A Blocked Card left by a closed Feature's Cycle — a candidate this Night's selection may adopt
/// rather than author a replacement for (feature-authoring/select-the-next-feature, first story).
public struct AdoptionCandidate: Equatable, Sendable {
    public let issueID: String
    public let repository: String

    public init(issueID: String, repository: String) {
        self.issueID = issueID
        self.repository = repository
    }
}

/// What the model-authored selection (``FeatureSelecting``) is handed to judge from: this Project's
/// specification, its configured repositories and their Repo Roles, resolved mainlines, an Operator's
/// forced Feature name (overriding selection when present), and the Blocked Cards a closed Feature
/// left behind.
public struct FeatureSelectionRequest: Equatable, Sendable {
    public let specificationSource: ProjectSpecificationSource
    /// The specification source's resolved mainline, when one was read.
    public let specificationMainline: ResolvedMainline?
    /// This Project's working repositories, carrying their configured Repo Roles.
    public let repos: [Repo]
    public let mainlines: ResolvedMainlines
    /// The Feature the Operator forced authoring for, overriding selection.
    public let namedFeature: FeatureName?
    public let adoptionCandidates: [AdoptionCandidate]

    public init(
        specificationSource: ProjectSpecificationSource,
        specificationMainline: ResolvedMainline?,
        repos: [Repo],
        mainlines: ResolvedMainlines,
        namedFeature: FeatureName?,
        adoptionCandidates: [AdoptionCandidate]
    ) {
        self.specificationSource = specificationSource
        self.specificationMainline = specificationMainline
        self.repos = repos
        self.mainlines = mainlines
        self.namedFeature = namedFeature
        self.adoptionCandidates = adoptionCandidates
    }
}

/// Where a selected Feature sits in a sequence (feature-authoring/select-the-next-feature, second
/// story): what came before, what is expected to follow, and why the seam falls where it does.
public struct FeatureSequence: Equatable, Sendable {
    public let precededBy: String
    public let followedBy: String
    public let seam: String

    public init(precededBy: String, followedBy: String, seam: String) {
        self.precededBy = precededBy
        self.followedBy = followedBy
        self.seam = seam
    }
}

/// The Feature the model-authored selection chose, with the reasoning and repositories to record on
/// it, and the Blocked Cards it adopts rather than replaces.
public struct SelectedFeature: Equatable, Sendable {
    public let name: FeatureName
    public let reasoning: String
    /// Non-nil when this Feature is one step of a sequence.
    public let sequence: FeatureSequence?
    public let repositories: [String]
    public let adoptedCardIssueIDs: [String]

    public init(
        name: FeatureName,
        reasoning: String,
        sequence: FeatureSequence?,
        repositories: [String],
        adoptedCardIssueIDs: [String]
    ) {
        self.name = name
        self.reasoning = reasoning
        self.sequence = sequence
        self.repositories = repositories
        self.adoptedCardIssueIDs = adoptedCardIssueIDs
    }
}

/// Why authoring halted before any dispatch (feature-authoring/select-the-next-feature, second and
/// fourth stories). Distinct from Refusal, which the glossary reserves for the thin-spec finding
/// (roadmap P9.5): a halt here is the seam problem or the repository-determination problem, not a
/// citation the specification could not support.
public enum AuthoringHaltReason: Equatable, Sendable {
    /// A genuinely atomic breaking change across repositories could not be split into a sequence of
    /// independently mergeable Features: no backward-compatible seam was found.
    case noBackwardCompatibleSeam(seam: String)
    /// The repositories this Feature touches could not be determined at all.
    case repositoriesUndetermined
    /// A repository the Feature named is not one of this Project's configured repositories.
    case contractOutsideProject(repository: String)

    /// A stable, machine-readable name for this reason, for the Journal's payload.
    public var kind: String {
        switch self {
        case .noBackwardCompatibleSeam: "no-backward-compatible-seam"
        case .repositoriesUndetermined: "repositories-undetermined"
        case .contractOutsideProject: "contract-outside-project"
        }
    }

    /// The seam or the repository this reason names, when it names one.
    public var detail: String? {
        switch self {
        case .noBackwardCompatibleSeam(let seam): seam
        case .repositoriesUndetermined: nil
        case .contractOutsideProject(let repository): repository
        }
    }
}

extension AuthoringHaltReason: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noBackwardCompatibleSeam(let seam):
            return "No backward-compatible seam could be found: \(seam)"
        case .repositoriesUndetermined:
            return "The repositories this Feature touches could not be determined."
        case .contractOutsideProject(let repository):
            return "Repository '\(repository)' is not configured for this Project."
        }
    }
}

/// What the model-authored selection (``FeatureSelecting``) found.
public enum FeatureSelectionOutcome: Equatable, Sendable {
    case selected(SelectedFeature)
    /// The specification yielded no selectable Feature: a quiet Night, not a failure.
    case noSelectableFeature
    /// The selected Feature could not be authored — the seam or repository problem this reason names.
    case halted(feature: FeatureName, reason: AuthoringHaltReason)
}
