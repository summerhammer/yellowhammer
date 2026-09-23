import Domain
import Foundation
import Journal

/// The model-authored judgement (roadmap P9.3; spec: feature-authoring/select-the-next-feature): reads
/// the specification and the Project's repositories to choose one Feature, or says there is nothing to
/// select, or that the Feature it chose cannot be authored. It judges; ``FeatureSelection`` validates
/// what it returns and records it. ``RoutedFeatureSelector`` is the agent CLI implementation; it throws
/// ``AuthoringDispatchFault`` when no Route answered, which ``FeatureSelection`` records as an authoring
/// fault. `context` is the Act's, for the Journal and the run.
public protocol FeatureSelecting: Sendable {
    func select(_ request: FeatureSelectionRequest, context: ActContext) async throws -> FeatureSelectionOutcome
}

/// Authors a validated ``SelectedFeature`` — the Feature Issue, its Cards and its adoptions (P9.4–P9.7).
/// ``AuthoringTransaction`` is the P9.4 implementation.
public protocol SelectedFeatureAuthoring: Sendable {
    /// `reselectionDepth` is how many Features the re-selection walk (roadmap P11.6; bounds/
    /// bound-re-selections) walked past before this one — 0 for the Night's first selection — carried
    /// onto a thin-spec Refusal's ``RefusalFinding``.
    func author(
        _ selection: SelectedFeature, reselectionDepth: Int, context: ActContext
    ) async throws -> FeatureAuthoringOutcome

    /// Finishes an authoring transaction an earlier Act accepted and did not complete, if there is one;
    /// nil when there is nothing to resume. Called before the selector runs, so a resume never selects
    /// (or breaks down) the Feature a second time.
    func resumeUnfinished(_ context: ActContext) async throws -> FeatureAuthoringOutcome?
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
    /// The re-selection walk (roadmap P11.6; bounds/overview) got back a Feature it already
    /// refused earlier this Night: the selector was handed the refused list and ignored it.
    case reselectedFeatureAlreadyRefused(FeatureName)
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
        case .reselectedFeatureAlreadyRefused(let feature):
            return """
                The re-selection walk was handed Feature '\(feature)' again after it was already refused \
                this Night.
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
    public let operatorIdentity: OperatorIdentity
    /// The re-selection walk's bound (roadmap P11.6; bounds/overview): how many Features a
    /// Night may walk past, after the first selection, before authoring gives up. Defaults to the
    /// glossary's own default of 2.
    public let reselectionsMax: Int

    public init(
        selector: any FeatureSelecting, transaction: (any SelectedFeatureAuthoring)? = nil,
        operatorIdentity: OperatorIdentity = .none, reselectionsMax: Int = 2
    ) {
        self.selector = selector
        self.transaction = transaction
        self.operatorIdentity = operatorIdentity
        self.reselectionsMax = reselectionsMax
    }

    public func selectAndAuthor(_ context: ActContext) async throws -> FeatureAuthoringOutcome {
        if let transaction, let resumed = try await transaction.resumeUnfinished(context) {
            return resumed
        }
        guard let repositories = context.repositories, !repositories.workingRepos.isEmpty else {
            throw FeatureSelectionError.noRepositoriesConfigured
        }
        let specSource = try Self.specificationSource(repositories)
        let candidates = try context.journal.blockedCardsLeftByClosedFeatures().map {
            AdoptionCandidate(issueID: $0.issueID, repository: $0.repository)
        }
        // The Operator named one Feature: the walk never re-selects (roadmap P11.6).
        var walk = WalkProgress(depth: 0, refusedThisNight: [], allowsReselection: context.trigger.namedFeature == nil)

        while true {
            let request = FeatureSelectionRequest(
                specificationSource: specSource,
                specificationMainline: Self.specificationMainline(specSource, mainlines: context.mainlines),
                repos: repositories.workingRepos,
                mainlines: context.mainlines,
                namedFeature: context.trigger.namedFeature,
                adoptionCandidates: candidates,
                refusedThisNight: walk.refusedThisNight
            )

            let outcome: FeatureSelectionOutcome
            do {
                outcome = try await selector.select(request, context: context)
            } catch let fault as AuthoringDispatchFault {
                // An authoring fault (roadmap P9.10, P9.11): no Feature was chosen and nothing was
                // written to the board, so there is no halt, no Refusal and nothing to answer.
                try context.journal.append(
                    .featureSelectionFailed(reason: fault.reason),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
                return .authoringRolledBack
            }

            switch outcome {
            case .noSelectableFeature:
                return .noWorkAvailable
            case .halted(let feature, let cause):
                return try await recordHalt(feature: feature, cause: cause, context: context)
            case .selected(let selected):
                if let stop = try await handleSelected(
                    selected, repositories: repositories, candidates: candidates, walk: &walk, context: context
                ) {
                    return stop
                }
            }
        }
    }

    /// The re-selection walk's mutable progress (roadmap P11.6): how deep it has gone, which Features it
    /// has already refused this Night, and whether the trigger even allows re-selecting (never, for an
    /// Operator-named Feature). Bundled to keep `handleSelected(_:repositories:candidates:walk:context:)`
    /// within the parameter count limit.
    private struct WalkProgress {
        var depth: Int
        var refusedThisNight: [FeatureName]
        let allowsReselection: Bool
    }

    /// One `.selected` outcome of the re-selection walk (roadmap P11.6): validates and records it, then
    /// either returns the outcome to stop the walk with, or advances `walk` and returns nil to keep
    /// walking. Split out of `selectAndAuthor(_:)` to keep that function within the length limit.
    private func handleSelected(
        _ selected: SelectedFeature, repositories: ProjectRepositories, candidates: [AdoptionCandidate],
        walk: inout WalkProgress, context: ActContext
    ) async throws -> FeatureAuthoringOutcome? {
        if walk.refusedThisNight.contains(selected.name) {
            throw FeatureSelectionError.reselectedFeatureAlreadyRefused(selected.name)
        }
        let result = try await validateAndRecord(
            selected, repositories: repositories, candidates: candidates, reselectionDepth: walk.depth,
            context: context
        )
        guard case .refused = result, walk.allowsReselection else { return result }
        guard walk.depth < reselectionsMax else {
            try context.journal.append(
                .reselectionBoundReached(depth: walk.depth, reselectionsMax: reselectionsMax),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            return .refused
        }
        walk.depth += 1
        try context.journal.append(
            .featureReselected(
                depth: walk.depth, afterRefusalOf: selected.name.rawValue, reselectionsMax: reselectionsMax
            ),
            act: context.act, runID: context.runID, nightID: context.night.id
        )
        walk.refusedThisNight.append(selected.name)
        return nil
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
        candidates: [AdoptionCandidate], reselectionDepth: Int, context: ActContext
    ) async throws -> FeatureAuthoringOutcome {
        if let named = context.trigger.namedFeature, named != selected.name {
            throw FeatureSelectionError.namedFeatureIgnored(named: named, selected: selected.name)
        }
        guard !selected.repositories.isEmpty else {
            return try await recordHalt(
                feature: selected.name, cause: .repositoriesUndetermined, context: context
            )
        }
        let sortedRepositories = Set(selected.repositories).sorted()
        if let outside = sortedRepositories.first(where: { repositories.workingRepo(named: $0) == nil }) {
            return try await recordHalt(
                feature: selected.name, cause: .contractOutsideProject(repository: outside), context: context
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
        return try await transaction.author(validated, reselectionDepth: reselectionDepth, context: context)
    }

    /// Records a halt durably and routes it to Waiting on You, through the halt path
    /// ``AuthoringTransaction`` shares for the unreadable contract (roadmap P9.6).
    private func recordHalt(
        feature: FeatureName, cause: AuthoringHaltCause, context: ActContext
    ) async throws -> FeatureAuthoringOutcome {
        try await AuthoringHalt.record(
            feature: feature, cause: cause, context: context, operatorIdentity: operatorIdentity
        )
    }
}
