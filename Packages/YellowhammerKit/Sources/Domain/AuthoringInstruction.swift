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
    /// The validated Feature to break down; non-nil exactly for the breakdown pass.
    public let selectedFeature: SelectedFeature?
    /// The absolute path the CLI must write its result file to.
    public let resultFilePath: String

    public init(
        pass: RunPass,
        route: Route,
        specificationSource: ProjectSpecificationSource,
        specificationMainline: ResolvedMainline?,
        repos: [Repo],
        mainlines: ResolvedMainlines,
        namedFeature: FeatureName?,
        adoptionCandidates: [AdoptionCandidate],
        selectedFeature: SelectedFeature?,
        resultFilePath: String
    ) {
        self.pass = pass
        self.route = route
        self.specificationSource = specificationSource
        self.specificationMainline = specificationMainline
        self.repos = repos
        self.mainlines = mainlines
        self.namedFeature = namedFeature
        self.adoptionCandidates = adoptionCandidates
        self.selectedFeature = selectedFeature
        self.resultFilePath = resultFilePath
    }

    /// This instruction with its result file path replaced.
    public func withResultFilePath(_ path: String) -> AuthoringInstruction {
        AuthoringInstruction(
            pass: pass, route: route, specificationSource: specificationSource,
            specificationMainline: specificationMainline, repos: repos, mainlines: mainlines,
            namedFeature: namedFeature, adoptionCandidates: adoptionCandidates,
            selectedFeature: selectedFeature, resultFilePath: path
        )
    }
}

/// What one dispatched pass is told to do: a Card's architect, worker or reviewer pass, or one of the
/// author Act's passes.
public enum AgentInstruction: Equatable, Sendable {
    case card(Instruction)
    case authoring(AuthoringInstruction)

    /// The Card instruction, when this is a Card's pass.
    public var cardInstruction: Instruction? {
        if case .card(let instruction) = self { instruction } else { nil }
    }

    public func render() -> String {
        switch self {
        case .card(let instruction): instruction.render()
        case .authoring(let instruction): instruction.render()
        }
    }

    /// This instruction with its result file path replaced.
    public func withResultFilePath(_ path: String) -> AgentInstruction {
        switch self {
        case .card(let instruction): .card(instruction.withResultFilePath(path))
        case .authoring(let instruction): .authoring(instruction.withResultFilePath(path))
        }
    }
}
