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
    /// Features refused earlier in this Night's re-selection walk (roadmap P11.6; bounds/
    /// bound-re-selections): the selector must not choose one of these again. Empty until the walk
    /// re-selects for the first time.
    public let refusedThisNight: [FeatureName]

    public init(
        specificationSource: ProjectSpecificationSource,
        specificationMainline: ResolvedMainline?,
        repos: [Repo],
        mainlines: ResolvedMainlines,
        namedFeature: FeatureName?,
        adoptionCandidates: [AdoptionCandidate],
        refusedThisNight: [FeatureName] = []
    ) {
        self.specificationSource = specificationSource
        self.specificationMainline = specificationMainline
        self.repos = repos
        self.mainlines = mainlines
        self.namedFeature = namedFeature
        self.adoptionCandidates = adoptionCandidates
        self.refusedThisNight = refusedThisNight
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
    public let workCardTitle: String?
    public let text: String
    public let citation: String
    public let reason: String

    public init(level: String, workCardTitle: String?, text: String, citation: String, reason: String) {
        self.level = level
        self.workCardTitle = workCardTitle
        self.text = text
        self.citation = citation
        self.reason = reason
    }
}

/// One contract the author Act could not read from another repository's merged mainline (roadmap P9.6;
/// spec: feature-authoring/author-an-architectural-brief): named specifically enough to act on — the
/// Card that needed it, the repository and paths it could not be read from, and why.
public struct UnreadableContract: Equatable, Sendable {
    public let workCardTitle: String
    public let repository: String
    public let paths: [String]
    public let reason: String

    public init(workCardTitle: String, repository: String, paths: [String], reason: String) {
        self.workCardTitle = workCardTitle
        self.repository = repository
        self.paths = paths
        self.reason = reason
    }
}

/// Why authoring halted before any dispatch (feature-authoring/select-the-next-feature, second and
/// fourth stories; feature-authoring/author-an-architectural-brief for ``contractUnreadable``): the seam
/// problem, the repository-determination problem or an unreadable contract. Deliberately not the thin-spec
/// finding — that is a ``RefusalFinding``, a separate object the glossary keeps apart from an Authoring Halt.
public enum AuthoringHaltCause: Equatable, Sendable {
    /// A genuinely atomic breaking change across repositories could not be split into a sequence of
    /// independently mergeable Features: no backward-compatible seam was found.
    case noBackwardCompatibleSeam(seam: String)
    /// The repositories this Feature touches could not be determined at all.
    case repositoriesUndetermined
    /// A repository the Feature named is not one of this Project's configured repositories.
    case contractOutsideProject(repository: String)
    /// A Card names a contract the author Act could not read from its repository's merged mainline —
    /// unconfigured, missing, or content that could not round-trip through the Managed Block (roadmap
    /// P9.6, spec: feature-authoring/author-an-architectural-brief). A Card is never authored
    /// speculatively without it.
    case contractUnreadable(contracts: [UnreadableContract])

    /// A stable, machine-readable name for this cause, for the Journal's payload.
    public var kind: String {
        switch self {
        case .noBackwardCompatibleSeam: "no-backward-compatible-seam"
        case .repositoriesUndetermined: "repositories-undetermined"
        case .contractOutsideProject: "contract-outside-project"
        case .contractUnreadable: "contract-unreadable"
        }
    }

    /// The seam or the repository this cause names, when it names one; a compact listing of every
    /// unreadable contract for ``contractUnreadable``.
    public var detail: String? {
        switch self {
        case .noBackwardCompatibleSeam(let seam): seam
        case .repositoriesUndetermined: nil
        case .contractOutsideProject(let repository): repository
        case .contractUnreadable(let contracts):
            contracts.map { "\($0.workCardTitle):\($0.repository):\($0.paths.joined(separator: ","))" }
                .joined(separator: "; ")
        }
    }
}

extension AuthoringHaltCause: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noBackwardCompatibleSeam(let seam):
            return "No backward-compatible seam could be found: \(seam)"
        case .repositoriesUndetermined:
            return "The repositories this Feature touches could not be determined."
        case .contractOutsideProject(let repository):
            return "Repository '\(repository)' is not configured for this Project."
        case .contractUnreadable(let contracts):
            let named = contracts.map { contract -> String in
                "Card '\(contract.workCardTitle)': repository '\(contract.repository)' " +
                    "(\(contract.paths.joined(separator: ", "))) could not be read: \(contract.reason)"
            }.joined(separator: "; ")
            return "A contract this author Act cannot read blocks authoring: \(named)"
        }
    }
}

/// The thin-spec finding behind a Refusal (roadmap P9.5, P9.8; glossary: Refusal; spec: feature-authoring/
/// author-citable-definitions-of-done, second story): the Definition of Done clauses no citation
/// supported, and how deep in the backlog this Feature sat when it was found. A separate object from
/// ``AuthoringHaltCause`` — neither is named after, or a case of, the other.
public struct RefusalFinding: Equatable, Sendable {
    public let uncitable: [UncitableClause]
    /// How many Features the selection walked past before this one; 0 until the backlog walk lands (P11.6).
    public let reselectionDepth: Int

    public init(uncitable: [UncitableClause], reselectionDepth: Int) {
        self.uncitable = uncitable
        self.reselectionDepth = reselectionDepth
    }

    /// A compact listing of every uncitable clause, for the Journal's payload.
    public var clauseListing: String {
        uncitable.map { "\($0.level):\($0.workCardTitle ?? "-"):\($0.text)" }.joined(separator: "; ")
    }
}

extension RefusalFinding: CustomStringConvertible {
    public var description: String {
        let named = uncitable.map { clause -> String in
            let location = clause.workCardTitle.map { "Card '\($0)'" } ?? "the Feature"
            return "\(location): clause '\(clause.text)' citing '\(clause.citation)' does not resolve: " +
                clause.reason
        }.joined(separator: "; ")
        return "The Definition of Done is not citable enough to dispatch (re-selection depth " +
            "\(reselectionDepth)): \(named)"
    }
}

/// What the model-authored selection (``FeatureSelecting``) found.
public enum FeatureSelectionOutcome: Equatable, Sendable {
    case selected(SelectedFeature)
    /// The specification yielded no selectable Feature: a quiet Night, not a failure.
    case noSelectableFeature
    /// The selected Feature could not be authored — the seam or repository problem this cause names.
    case halted(feature: FeatureName, cause: AuthoringHaltCause)
}
