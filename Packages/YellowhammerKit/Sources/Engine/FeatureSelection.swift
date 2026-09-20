import Domain
import Foundation
import Journal

/// The model-authored judgement (roadmap P9.3; spec: feature-authoring/select-the-next-feature): reads
/// the specification and the Project's repositories to choose one Feature, or says there is nothing to
/// select, or that the Feature it chose cannot be authored. It judges; ``FeatureSelection`` validates
/// what it returns and records it. No implementation ships in this phase.
public protocol FeatureSelecting: Sendable {
    func select(_ request: FeatureSelectionRequest) async throws -> FeatureSelectionOutcome
}

/// Authors a validated ``SelectedFeature`` — the Feature Issue, its Cards and its adoptions (P9.4–P9.7).
/// No implementation ships in this phase.
public protocol SelectedFeatureAuthoring: Sendable {
    func author(_ selection: SelectedFeature, context: ActContext) async throws
}

/// What is wrong with this Project's configuration, or with what the selector returned, such that
/// selection refuses to guess.
public enum FeatureSelectionError: Error, Sendable, Equatable {
    /// This Project has no repositories configured at all.
    case noRepositoriesConfigured
    /// This Project has no specification source configured.
    case noSpecificationSource
    /// This Project has more than one specification source configured — exactly one is a Project
    /// invariant, checked at setup, but never guessed here.
    case multipleSpecificationSources([String])
    /// The Operator forced authoring for a Feature they named, but the selector chose a different one.
    case namedFeatureIgnored(named: FeatureName, selected: FeatureName)
}

extension FeatureSelectionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noRepositoriesConfigured:
            return "This Project has no repositories configured; feature selection cannot run."
        case .noSpecificationSource:
            return "This Project has no specification source configured; feature selection cannot run."
        case .multipleSpecificationSources(let names):
            return """
                This Project has more than one specification source configured: \(names.joined(separator: ", ")).
                """
        case .namedFeatureIgnored(let named, let selected):
            return """
                The Operator forced authoring for Feature '\(named)', but selection chose '\(selected)' instead.
                """
        }
    }
}

/// Selects and authors the next Feature (roadmap P9.3; spec: feature-authoring/select-the-next-feature).
/// Runs the model-authored ``FeatureSelecting`` seam exactly once, validates what it returns against
/// this Project's own configuration, records the selection or the halt durably, and only then hands a
/// validated selection to ``SelectedFeatureAuthoring`` (P9.4–P9.7). A halt allocates no Worktree,
/// dispatches nothing and records no Attempt.
public struct FeatureSelection: FeatureAuthoring {
    public let selector: any FeatureSelecting
    /// P9.4–P9.7's transaction; nil throws `notImplemented` once a selection is recorded, the same
    /// stance as `AuthorAct`'s nil `authoring`.
    public let transaction: (any SelectedFeatureAuthoring)?

    public init(selector: any FeatureSelecting, transaction: (any SelectedFeatureAuthoring)? = nil) {
        self.selector = selector
        self.transaction = transaction
    }

    public func selectAndAuthor(_ context: ActContext) async throws -> FeatureAuthoringOutcome {
        guard let repositories = context.repositories, !repositories.workingRepos.isEmpty else {
            throw FeatureSelectionError.noRepositoriesConfigured
        }
        let specSource = try Self.specificationSource(repositories)
        let candidates = try context.journal.blockedCardsLeftByClosedFeatures().map {
            AdoptionCandidate(issueID: $0.issueID, repository: $0.repository)
        }
        let request = FeatureSelectionRequest(
            specificationSource: specSource,
            specificationMainline: Self.specificationMainline(specSource, mainlines: context.mainlines),
            repos: repositories.workingRepos,
            mainlines: context.mainlines,
            namedFeature: context.trigger.namedFeature,
            adoptionCandidates: candidates
        )

        switch try await selector.select(request) {
        case .noSelectableFeature:
            return .noWorkAvailable
        case .halted(let feature, let reason):
            return try await recordHalt(feature: feature, reason: reason, context: context)
        case .selected(let selected):
            return try await validateAndRecord(
                selected, repositories: repositories, candidates: candidates, context: context
            )
        }
    }

    private static func specificationSource(_ repositories: ProjectRepositories) throws -> ProjectSpecificationSource {
        switch repositories.specificationSourceLookup {
        case .none:
            throw FeatureSelectionError.noSpecificationSource
        case .multiple(let names):
            throw FeatureSelectionError.multipleSpecificationSources(names)
        case .resolved(let source):
            return source
        }
    }

    private static func specificationMainline(
        _ source: ProjectSpecificationSource, mainlines: ResolvedMainlines
    ) -> ResolvedMainline? {
        switch source {
        case .specSource:
            return mainlines.specSource
        case .workingRepo(let repo):
            return mainlines[repo]
        }
    }

    /// Validates what the selector returned, engine-side, in the order the story requires: the forced
    /// name must match, the repositories must resolve to this Project's own, and adoption is narrowed
    /// to real candidates before anything is recorded.
    private func validateAndRecord(
        _ selected: SelectedFeature, repositories: ProjectRepositories,
        candidates: [AdoptionCandidate], context: ActContext
    ) async throws -> FeatureAuthoringOutcome {
        if let named = context.trigger.namedFeature, named != selected.name {
            throw FeatureSelectionError.namedFeatureIgnored(named: named, selected: selected.name)
        }
        guard !selected.repositories.isEmpty else {
            return try await recordHalt(
                feature: selected.name, reason: .repositoriesUndetermined, context: context
            )
        }
        let sortedRepositories = Set(selected.repositories).sorted()
        if let outside = sortedRepositories.first(where: { repositories.workingRepo(named: $0) == nil }) {
            return try await recordHalt(
                feature: selected.name, reason: .contractOutsideProject(repository: outside), context: context
            )
        }

        let candidateIDs = Set(candidates.map(\.issueID))
        let adopted = Set(selected.adoptedCardIssueIDs).intersection(candidateIDs).sorted()
        let adoptedSet = Set(adopted)
        let unadopted = candidates.map(\.issueID).filter { !adoptedSet.contains($0) }.sorted()

        let validated = SelectedFeature(
            name: selected.name, reasoning: selected.reasoning, sequence: selected.sequence,
            repositories: sortedRepositories, adoptedCardIssueIDs: adopted
        )
        try context.journal.append(
            .featureSelected(FeatureSelectedPayload(
                name: validated.name.rawValue,
                reasoning: validated.reasoning,
                precededBy: validated.sequence?.precededBy,
                followedBy: validated.sequence?.followedBy,
                seam: validated.sequence?.seam,
                repositories: validated.repositories,
                adoptedCardIssueIDs: validated.adoptedCardIssueIDs,
                unadoptedCardIssueIDs: unadopted
            )),
            act: context.act, runID: context.runID, nightID: context.night.id
        )

        guard let transaction else {
            throw EngineInvocationError.notImplemented(.author)
        }
        try await transaction.author(validated, context: context)
        return .authored
    }

    /// Records a halt durably before any board write, then — only when this invocation has an Outbox
    /// and a Board — puts the Feature in Waiting on You naming the reason. Allocates no Worktree,
    /// dispatches nothing, records no Attempt.
    private func recordHalt(
        feature: FeatureName, reason: AuthoringHaltReason, context: ActContext
    ) async throws -> FeatureAuthoringOutcome {
        try context.journal.append(
            .featureAuthoringHalted(name: feature.rawValue, reasonKind: reason.kind, detail: reason.detail),
            act: context.act, runID: context.runID, nightID: context.night.id
        )
        guard let outbox = context.outbox, let board = context.board else {
            return .halted
        }
        let scope = try await BoardStateScope.resolve(using: board.provisioning)
        guard let featureLabelID = scope.labels.objectType["Feature"] else {
            throw DispositionLabelsError.missing(group: BoardProvisioner.objectTypeGroup, label: "Feature")
        }
        let waitingOnYouID = try scope.id(for: .waitingOnYou)

        let createKey = "feature:\(feature.rawValue):halt:create"
        let draft = BoardIssueDraft(
            team: scope.team, title: feature.rawValue, labels: [featureLabelID], workflowState: waitingOnYouID
            // No assignee: the Operator's board identity is not wired until P11.
        )
        let delivery = try await outbox.post(OutboxWrite(key: createKey, write: .createIssue(draft, parentKey: nil)))

        let createdID: BoardObjectID?
        switch delivery.outcome {
        case .applied(let id):
            createdID = id
        case .alreadyApplied(let id):
            createdID = id
        default:
            createdID = nil
        }
        if let createdID {
            let commentKey = "feature:\(feature.rawValue):halt:\(context.night.nightStart.rawValue):comment"
            _ = try await outbox.post(OutboxWrite(
                key: commentKey, write: .createComment(issue: createdID, body: reason.description)
            ))
        }
        return .halted
    }
}
