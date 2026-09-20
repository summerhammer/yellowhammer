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

/// One Card the model-authored breakdown asks for (roadmap P9.4; spec: feature-authoring/
/// author-the-cycle-and-card-dag, first story): exactly one repository, one Kind, one unit of work, and
/// its own Card-level Definition of Done (roadmap P9.5).
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
    public let definitionOfDone: [DefinitionOfDoneClauseDraft]

    public init(
        repository: String, kind: Kind, title: String, unitOfWork: String,
        definitionOfDone: [DefinitionOfDoneClauseDraft] = []
    ) {
        self.repository = repository
        self.kind = kind
        self.title = title
        self.unitOfWork = unitOfWork
        self.definitionOfDone = definitionOfDone
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
