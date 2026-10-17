/// The instruction Yellowhammer composes and hands to the CLI for one pass of the author Act (roadmap
/// P9.11): selection chooses the next Feature, breakdown drafts a selected Feature's Cards. Like
/// ``Instruction`` it is data plus a deterministic text rendering — the instruction and the result
/// contract are ours; tools, context management and subagents are the CLI's.
public struct AuthoringInstruction: Equatable, Sendable {
    /// ``RunPass/selection`` or ``RunPass/breakdown``.
    public let pass: RunPass
    public let route: Route
    /// This Project's single specification source, and its resolved mainline when one was read.
    public let specificationSource: ProjectSpecificationSource
    public let specificationMainline: ResolvedMainline?
    /// The working repositories, carrying their Repo Roles and paths.
    public let repos: [Repo]
    public let mainlines: ResolvedMainlines
    /// The Feature the Operator forced authoring for, when they named one.
    public let namedFeature: FeatureName?
    public let adoptionCandidates: [AdoptionCandidate]
    /// Features refused earlier in this Night's re-selection walk (roadmap P11.6; bounds/
    /// bound-re-selections): the selector must not choose one of these again.
    public let refusedThisNight: [FeatureName]
    /// Consumer Repos the release gate holds back tonight; rendered for the selection pass only.
    public let heldConsumers: [HeldConsumer]
    /// The validated Feature to break down; non-nil exactly for the breakdown pass.
    public let selectedFeature: SelectedFeature?
    /// The room the Board Connection's description budget leaves each repository's Work Card, which the
    /// breakdown is told so it keeps each Card's whole description within it. Nil when the board enforces
    /// no budget.
    public let descriptionRoom: BreakdownDescriptionRoom?
    /// The invalid-output rejections of earlier Routes in this same walk, each already prefixed with its
    /// Route, so the next Route learns why the previous one's drafting was refused. Empty on the first Route.
    public let earlierRejections: [String]

    public init(
        pass: RunPass,
        route: Route,
        specificationSource: ProjectSpecificationSource,
        specificationMainline: ResolvedMainline?,
        repos: [Repo],
        mainlines: ResolvedMainlines,
        namedFeature: FeatureName?,
        adoptionCandidates: [AdoptionCandidate],
        refusedThisNight: [FeatureName] = [],
        heldConsumers: [HeldConsumer] = [],
        selectedFeature: SelectedFeature?,
        descriptionRoom: BreakdownDescriptionRoom? = nil,
        earlierRejections: [String] = []
    ) {
        self.pass = pass
        self.route = route
        self.specificationSource = specificationSource
        self.specificationMainline = specificationMainline
        self.repos = repos
        self.mainlines = mainlines
        self.namedFeature = namedFeature
        self.adoptionCandidates = adoptionCandidates
        self.refusedThisNight = refusedThisNight
        self.heldConsumers = heldConsumers
        self.selectedFeature = selectedFeature
        self.descriptionRoom = descriptionRoom
        self.earlierRejections = earlierRejections
    }
}

/// What one dispatched pass is told to do: a Card's architect, worker or reviewer pass, or one of the
/// author Act's passes, or the land Act's verifier pass.
public enum AgentInstruction: Equatable, Sendable {
    case card(Instruction)
    case authoring(AuthoringInstruction)
    case verification(VerificationInstruction)

    /// The Card instruction, when this is a Card's pass.
    public var cardInstruction: Instruction? {
        if case .card(let instruction) = self { instruction } else { nil }
    }

    public func render() -> String {
        switch self {
        case .card(let instruction): instruction.render()
        case .authoring(let instruction): instruction.render()
        case .verification(let instruction): instruction.render()
        }
    }
}
