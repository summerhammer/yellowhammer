/// A Blocked Card left by a closed Feature's Cycle — a candidate this Night's selection may adopt
/// rather than author a replacement for (feature-authoring/select-the-next-feature, first story).
public struct AdoptionCandidate: Equatable, Sendable {
    public let issueID: String
    public let repository: String
    /// The Card's title, when the Journal recorded one; rendered so the selector can recognise the Card.
    public let title: String?
    /// Why the Card was left Blocked, when the Journal recorded a reason.
    public let blockReason: String?

    public init(issueID: String, repository: String, title: String? = nil, blockReason: String? = nil) {
        self.issueID = issueID
        self.repository = repository
        self.title = title
        self.blockReason = blockReason
    }
}

/// A declared Repo Dependency whose consumer and producer a selected Feature both touches
/// (feature-authoring/select-the-next-feature, `#repo-dependency-halt`).
public struct SpannedRepoDependency: Equatable, Sendable {
    public let consumer: String
    public let producer: String
    public let via: RepoDependencyVia

    public init(consumer: String, producer: String, via: RepoDependencyVia) {
        self.consumer = consumer
        self.producer = producer
        self.via = via
    }
}

/// Why a consumer Repo is held back tonight (feature-authoring/select-the-next-feature, `#release-gate` and
/// `#effective-base`).
public enum ConsumerHold: String, Equatable, Sendable {
    /// The consumer reads the producer by tag, and no release of the producer contains the producer's latest
    /// Feature yet: an Observed Release is awaited.
    case awaitingRelease = "release"
    /// The producer has a Feature in the Unmerged Feature Stack U with no Observed Merge in the producer yet
    /// (roadmap P23.2): the consumer waits for that merge, whichever way it reads the producer.
    case awaitingMerge = "merge"
}

/// A consumer Repo the release gate holds back tonight: the producer's Feature `producerFeature` has no
/// Observed Merge in the producer yet (``ConsumerHold/awaitingMerge``), or the consumer reads `producer` by
/// tag and no release of the producer contains that Feature yet (``ConsumerHold/awaitingRelease``). Shown to
/// the selection model so it does not select a Feature that touches the consumer.
public struct HeldConsumer: Equatable, Sendable {
    public let consumer: String
    public let producer: String
    /// The Feature reference shown to the model.
    public let producerFeature: String
    /// The producer Feature's issue id, for the Journal and the Night Card; empty when not known.
    public let producerFeatureIssueID: String
    /// What the consumer waits for.
    public let hold: ConsumerHold

    public init(
        consumer: String, producer: String, producerFeature: String, producerFeatureIssueID: String = "",
        hold: ConsumerHold
    ) {
        self.consumer = consumer
        self.producer = producer
        self.producerFeature = producerFeature
        self.producerFeatureIssueID = producerFeatureIssueID
        self.hold = hold
    }
}

/// One Work Card reading, as a contract, paths in a repository that another Work Card of the same Feature writes
/// (feature-authoring/author-the-cycle-and-card-dag, `#contract-overlap`): the Feature carries its own upstream.
public struct ContractOverlap: Equatable, Sendable {
    public let readerTitle: String
    public let writerTitle: String
    public let repository: String
    public let paths: [String]

    public init(readerTitle: String, writerTitle: String, repository: String, paths: [String]) {
        self.readerTitle = readerTitle
        self.writerTitle = writerTitle
        self.repository = repository
        self.paths = paths
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
    /// Consumer Repos the release gate holds back tonight; empty until the release gate fills it.
    public let heldConsumers: [HeldConsumer]
    /// What the Journal knows of this Project's board, so the selection pass need not search for it.
    public let boardState: SelectionBoardState

    public init(
        specificationSource: ProjectSpecificationSource,
        specificationMainline: ResolvedMainline?,
        repos: [Repo],
        mainlines: ResolvedMainlines,
        namedFeature: FeatureName?,
        adoptionCandidates: [AdoptionCandidate],
        refusedThisNight: [FeatureName] = [],
        heldConsumers: [HeldConsumer] = [],
        boardState: SelectionBoardState = SelectionBoardState()
    ) {
        self.specificationSource = specificationSource
        self.specificationMainline = specificationMainline
        self.repos = repos
        self.mainlines = mainlines
        self.namedFeature = namedFeature
        self.adoptionCandidates = adoptionCandidates
        self.refusedThisNight = refusedThisNight
        self.heldConsumers = heldConsumers
        self.boardState = boardState
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
    case authoringRepeatedlyFaulted(count: Int, lastReason: String)
    /// The Feature touches both ends of a declared Repo Dependency (feature-authoring/select-the-next-feature,
    /// `#repo-dependency-seam`): every spanning edge is named, never only the first.
    case featureSpansRepoDependency(edges: [SpannedRepoDependency])
    /// A Work Card reads, as a contract, what another Work Card of the same Feature writes
    /// (feature-authoring/author-the-cycle-and-card-dag, `#contract-overlap`): found at breakdown validation
    /// with no model call, so it is an Authoring Halt, not invalid breakdown output.
    case breakdownConsumesOwnFeatureWork(overlaps: [ContractOverlap])

    /// A stable, machine-readable name for this cause, for the Journal's payload.
    public var kind: String {
        switch self {
        case .noBackwardCompatibleSeam: "no-backward-compatible-seam"
        case .repositoriesUndetermined: "repositories-undetermined"
        case .contractOutsideProject: "contract-outside-project"
        case .contractUnreadable: "contract-unreadable"
        case .authoringRepeatedlyFaulted: "authoring-repeatedly-faulted"
        case .featureSpansRepoDependency: "feature-spans-repo-dependency"
        case .breakdownConsumesOwnFeatureWork: "breakdown-consumes-own-feature-work"
        }
    }

    /// The seam or the repository this cause names, when it names one; a compact listing of every
    /// unreadable contract for ``contractUnreadable``.
    public var detail: String? {
        switch self {
        case .noBackwardCompatibleSeam(let seam): seam
        case .repositoriesUndetermined: nil
        case .authoringRepeatedlyFaulted(let count, let reason): "\(count): \(reason)"
        case .contractOutsideProject(let repository): repository
        case .contractUnreadable(let contracts):
            contracts.map { "\($0.workCardTitle):\($0.repository):\($0.paths.joined(separator: ","))" }
                .joined(separator: "; ")
        case .featureSpansRepoDependency(let edges):
            edges.map { "\($0.consumer)->\($0.producer)(\($0.via.rawValue))" }.joined(separator: "; ")
        case .breakdownConsumesOwnFeatureWork(let overlaps):
            overlaps.map { "\($0.readerTitle)|\($0.writerTitle)|\($0.repository)|\($0.paths.joined(separator: ","))" }
                .joined(separator: "; ")
        }
    }
}

extension AuthoringHaltCause {
    /// Names in first-seen order, each once.
    fileprivate static func listing(_ names: [String]) -> String {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }.joined(separator: ", ")
    }
}

extension AuthoringHaltCause: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noBackwardCompatibleSeam(let seam):
            return "No backward-compatible seam could be found: \(seam). "
                + "Change the specification, then move this Feature to Todo."
        case .repositoriesUndetermined:
            return "The repositories this Feature touches could not be determined. "
                + "Change the specification, then move this Feature to Todo."
        case .contractOutsideProject(let repository):
            return "Repository '\(repository)' is not configured for this Project. "
                + "Change the Project configuration, then move this Feature to Todo."
        case .authoringRepeatedlyFaulted(let count, let reason):
            return "authoring repeatedly faulted: faulted on its last \(count) authoring runs; last fault: \(reason). "
                + "Change the specification, then move this Feature to Todo."
        case .contractUnreadable(let contracts):
            let named = contracts.map { contract -> String in
                "Card '\(contract.workCardTitle)': repository '\(contract.repository)' " +
                    "(\(contract.paths.joined(separator: ", "))) could not be read: \(contract.reason)"
            }.joined(separator: "; ")
            return "A contract this author Act cannot read blocks authoring: \(named). "
                + "Edit this Feature's draft Work Cards first, then move this Feature to Todo."
        case .breakdownConsumesOwnFeatureWork(let overlaps):
            let named = overlaps.map {
                "Card '\($0.readerTitle)' reads \($0.repository) (\($0.paths.joined(separator: ", "))), "
                    + "which Card '\($0.writerTitle)' writes in this Feature"
            }.joined(separator: "; ")
            return "This breakdown consumes its own Feature's work: \(named). A Work Card can only read what "
                + "already exists at mainline. Declare the Repo Dependency (`consumes` on the consumer Repo) and "
                + "split the Feature: the upstream layer first, the consumer work in a later Feature once it has "
                + "merged. Edit this Feature's draft Work Cards first, then move this Feature to Todo."
        case .featureSpansRepoDependency(let edges):
            let named = edges.map { "\($0.consumer) → \($0.producer) (via \($0.via.rawValue))" }
                .joined(separator: ", ")
            let producers = Self.listing(edges.map(\.producer))
            let consumers = Self.listing(edges.map(\.consumer))
            return "This Feature spans a declared Repo Dependency: \(named). Split it: author the producer side "
                + "(\(producers)) as its own Feature first; the consumer work (\(consumers)) follows in a later "
                + "Feature once the producer's work has an Observed Merge and, for a `tag` edge, an Observed "
                + "Release. Force a narrower Feature, or change the Project configuration, "
                + "then move this Feature to Todo."
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
