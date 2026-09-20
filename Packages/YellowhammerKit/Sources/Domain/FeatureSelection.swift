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

/// One Definition of Done clause the author Act could not cite (roadmap P9.5; spec: feature-authoring/
/// author-citable-definitions-of-done, second story): named specifically enough to act on — its level,
/// the Card it belonged to when it was Card-level, its text, the citation it carried, and why the
/// resolver refused it.
public struct UncitableClause: Equatable, Sendable {
    /// `"feature"` or `"card"`.
    public let level: String
    /// The Card's title, when ``level`` is `"card"`; nil for a Feature-level clause.
    public let cardTitle: String?
    public let text: String
    public let citation: String
    public let reason: String

    public init(level: String, cardTitle: String?, text: String, citation: String, reason: String) {
        self.level = level
        self.cardTitle = cardTitle
        self.text = text
        self.citation = citation
        self.reason = reason
    }
}

/// One contract the author Act could not read from another repository's merged mainline (roadmap P9.6;
/// spec: feature-authoring/author-an-architectural-brief): named specifically enough to act on — the
/// Card that needed it, the repository and paths it could not be read from, and why.
public struct UnreadableContract: Equatable, Sendable {
    public let cardTitle: String
    public let repository: String
    public let paths: [String]
    public let reason: String

    public init(cardTitle: String, repository: String, paths: [String], reason: String) {
        self.cardTitle = cardTitle
        self.repository = repository
        self.paths = paths
        self.reason = reason
    }
}

/// Why authoring halted before any dispatch (feature-authoring/select-the-next-feature, second and
/// fourth stories; feature-authoring/author-citable-definitions-of-done, second story, for
/// ``uncitableDefinitionOfDone``). Distinct from Refusal, which the glossary reserves for the thin-spec
/// finding: every other case here is the seam problem or the repository-determination problem, not a
/// citation the specification could not support.
public enum AuthoringHaltReason: Equatable, Sendable {
    /// A genuinely atomic breaking change across repositories could not be split into a sequence of
    /// independently mergeable Features: no backward-compatible seam was found.
    case noBackwardCompatibleSeam(seam: String)
    /// The repositories this Feature touches could not be determined at all.
    case repositoriesUndetermined
    /// A repository the Feature named is not one of this Project's configured repositories.
    case contractOutsideProject(repository: String)
    /// After dropping every clause whose citation did not resolve, the Feature level or at least one
    /// newly authored Card was left with zero clauses: the Feature's spec support is too thin (roadmap
    /// P9.5, second story). This is the Refusal the glossary names.
    case uncitableDefinitionOfDone(clauses: [UncitableClause])
    /// A Card names a contract the author Act could not read from its repository's merged mainline —
    /// unconfigured, missing, or content that could not round-trip through the Managed Block (roadmap
    /// P9.6, spec: feature-authoring/author-an-architectural-brief). A Card is never authored
    /// speculatively without it.
    case contractUnreadable(contracts: [UnreadableContract])

    /// A stable, machine-readable name for this reason, for the Journal's payload.
    public var kind: String {
        switch self {
        case .noBackwardCompatibleSeam: "no-backward-compatible-seam"
        case .repositoriesUndetermined: "repositories-undetermined"
        case .contractOutsideProject: "contract-outside-project"
        case .uncitableDefinitionOfDone: "uncitable-definition-of-done"
        case .contractUnreadable: "contract-unreadable"
        }
    }

    /// The seam or the repository this reason names, when it names one; a compact listing of every
    /// uncitable clause for ``uncitableDefinitionOfDone``, or every unreadable contract for
    /// ``contractUnreadable``.
    public var detail: String? {
        switch self {
        case .noBackwardCompatibleSeam(let seam): seam
        case .repositoriesUndetermined: nil
        case .contractOutsideProject(let repository): repository
        case .uncitableDefinitionOfDone(let clauses):
            clauses.map { "\($0.level):\($0.cardTitle ?? "-"):\($0.text)" }.joined(separator: "; ")
        case .contractUnreadable(let contracts):
            contracts.map { "\($0.cardTitle):\($0.repository):\($0.paths.joined(separator: ","))" }
                .joined(separator: "; ")
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
        case .uncitableDefinitionOfDone(let clauses):
            let named = clauses.map { clause -> String in
                let location = clause.cardTitle.map { "Card '\($0)'" } ?? "the Feature"
                return "\(location): clause '\(clause.text)' citing '\(clause.citation)' does not resolve: " +
                    clause.reason
            }.joined(separator: "; ")
            return "The Definition of Done is not citable enough to dispatch: \(named)"
        case .contractUnreadable(let contracts):
            let named = contracts.map { contract -> String in
                "Card '\(contract.cardTitle)': repository '\(contract.repository)' " +
                    "(\(contract.paths.joined(separator: ", "))) could not be read: \(contract.reason)"
            }.joined(separator: "; ")
            return "A contract this author Act cannot read blocks authoring: \(named)"
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
