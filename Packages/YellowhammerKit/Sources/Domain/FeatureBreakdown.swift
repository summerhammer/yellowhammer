/// One Definition of Done clause as drafted during authoring, before its citation is resolved (roadmap
/// P9.5; spec: feature-authoring/author-citable-definitions-of-done, first story). The author Act can
/// only write a clause it can cite: ``AuthoringTransaction`` resolves ``citation`` against the
/// specification before any of this is accepted into the Outbox, and drops the clause when it does not.
public struct DefinitionOfDoneClauseDraft: Equatable, Sendable {
    public let text: String
    public let citation: SpecCitation

    public init(text: String, citation: SpecCitation) {
        self.text = text
        self.citation = citation
    }
}

/// One contract a Card names to be transcribed from another repository's merged mainline (roadmap
/// P9.6; spec: feature-authoring/author-an-architectural-brief): the model only NAMES what to read — it
/// never supplies transcribed content, a commit or a hash. ``ContractTranscribing`` reads it before
/// anything is accepted into the Outbox.
public struct ContractDraft: Equatable, Sendable {
    public let repository: String
    /// Every path the contract must be read from — the stamp the Readiness Check later diffs is only as
    /// good as the paths named here.
    public let paths: [String]
    public let symbol: String?

    public init(repository: String, paths: [String], symbol: String? = nil) {
        self.repository = repository
        self.paths = paths
        self.symbol = symbol
    }
}

/// One Card the model-authored breakdown asks for (roadmap P9.4; spec: feature-authoring/
/// author-the-cycle-and-card-dag, first story): exactly one repository, one Kind, one unit of work, its
/// own Architectural Brief (roadmap P9.6) and its own Card-level Definition of Done (roadmap P9.5).
///
/// It deliberately has NO field that could reference another Card — no predecessor, no dependency, no
/// sibling. That is how "no Card-to-Card links" is enforced structurally: a breakdown cannot express an
/// ordering edge, so none can reach the board. Order within a repository is the draft's position (see
/// ``FeatureBreakdown``), a resource choice for the lane's one Worktree and never a dependency.
public struct CardDraft: Equatable, Sendable {
    public let repository: String
    public let kind: Kind
    public let title: String
    public let unitOfWork: String
    /// The Architectural Brief's approach prose (roadmap P9.6; spec: feature-authoring/
    /// author-an-architectural-brief) — model-authored, distinct from ``unitOfWork`` and from the
    /// Definition of Done. Every authored Card has one: ``FeatureBreakdownValidation`` refuses a blank
    /// brief before anything is accepted into the Outbox.
    public let brief: String
    public let definitionOfDone: [DefinitionOfDoneClauseDraft]
    /// Contracts this Card consumes from another repository's merged mainline, each transcribed into its
    /// own Transcription Block before this Card is authored (roadmap P9.6).
    public let contracts: [ContractDraft]

    public init(
        repository: String, kind: Kind, title: String, unitOfWork: String, brief: String,
        definitionOfDone: [DefinitionOfDoneClauseDraft] = [], contracts: [ContractDraft] = []
    ) {
        self.repository = repository
        self.kind = kind
        self.title = title
        self.unitOfWork = unitOfWork
        self.brief = brief
        self.definitionOfDone = definitionOfDone
        self.contracts = contracts
    }
}

/// What the model-authored breakdown returned for one selected Feature: the Feature-level definition of
/// done and the Cards to author. A Card's authored order within its repository is its 1-based position
/// among the drafts of the same repository, in array order.
public struct FeatureBreakdown: Equatable, Sendable {
    public let definitionOfDone: [DefinitionOfDoneClauseDraft]
    public let cards: [CardDraft]

    public init(definitionOfDone: [DefinitionOfDoneClauseDraft], cards: [CardDraft]) {
        self.definitionOfDone = definitionOfDone
        self.cards = cards
    }
}
