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

    /// Authors a repaired halted Feature from the Board snapshot of its draft children instead of drafting a
    /// breakdown (roadmap P22.6): the same validation as ``author(_:reselectionDepth:context:)``, then the
    /// drafts become the Cycle's Work Cards under their existing issue ids.
    func authorRepaired(
        _ selection: SelectedFeature, snapshot: HaltRepairSnapshot, reselectionDepth: Int, context: ActContext
    ) async throws -> FeatureAuthoringOutcome
}

extension SelectedFeatureAuthoring {
    /// An authoring with no draft children of its own authors the selection as usual.
    public func authorRepaired(
        _ selection: SelectedFeature, snapshot: HaltRepairSnapshot, reselectionDepth: Int, context: ActContext
    ) async throws -> FeatureAuthoringOutcome {
        try await author(selection, reselectionDepth: reselectionDepth, context: context)
    }
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
    /// The re-selection walk's bound (roadmap P11.6; bounds/overview): how many Features a
    /// Night may walk past, after the first selection, before authoring gives up. Defaults to the
    /// glossary's own default of 2.
    public let reselectionsMax: Int
    public let consecutiveAuthoringFaultsMax: Int
    /// The release gate for `tag` Repo Dependencies, run once before selection; nil holds nothing.
    public let releaseGate: (any ReleaseGate)?

    public init(
        selector: any FeatureSelecting, transaction: (any SelectedFeatureAuthoring)? = nil, reselectionsMax: Int = 2,
        consecutiveAuthoringFaultsMax: Int = 3, releaseGate: (any ReleaseGate)? = nil
    ) {
        self.releaseGate = releaseGate
        self.selector = selector
        self.transaction = transaction
        self.reselectionsMax = reselectionsMax
        self.consecutiveAuthoringFaultsMax = consecutiveAuthoringFaultsMax
    }

    public func selectAndAuthor(_ context: ActContext) async throws -> FeatureAuthoringOutcome {
        if let resumed = try await resumeEarlierWork(context) {
            return resumed
        }
        guard let repositories = context.repositories, !repositories.workingRepos.isEmpty else {
            throw FeatureSelectionError.noRepositoriesConfigured
        }
        let specSource = try Self.specificationSource(repositories)
        let candidates = try context.journal.blockedCardsLeftByClosedFeatures().map {
            AdoptionCandidate(
                issueID: $0.issueID, repository: $0.repository, title: $0.title, blockReason: $0.blockReason
            )
        }
        let held = try await releaseGate?.heldConsumers(context) ?? []
        let scope = SelectionScope(
            repositories: repositories, candidates: candidates, held: held,
            boardState: try context.journal.selectionBoardState()
        )
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
                refusedThisNight: walk.refusedThisNight,
                heldConsumers: held, boardState: scope.boardState
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
                return try await recordHalt(feature: feature, cause: cause, selection: nil, context: context)
            case .selected(let selected):
                if let stop = try await handleSelected(selected, scope: scope, walk: &walk, context: context) {
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

    /// What a `.selected` outcome is validated against: this Project's repositories, the Blocked Cards
    /// adoption may take, and the consumers the release gate holds tonight.
    struct SelectionScope {
        let repositories: ProjectRepositories
        let candidates: [AdoptionCandidate]
        let held: [HeldConsumer]
        /// What the Journal knows of the board, including the Unmerged Feature Stack U a selection must not
        /// name again (roadmap P23.2).
        let boardState: SelectionBoardState
    }

    /// One `.selected` outcome of the re-selection walk (roadmap P11.6): validates and records it, then
    /// either returns the outcome to stop the walk with, or advances `walk` and returns nil to keep
    /// walking. Split out of `selectAndAuthor(_:)` to keep that function within the length limit.
    private func handleSelected(
        _ selected: SelectedFeature, scope: SelectionScope, walk: inout WalkProgress, context: ActContext
    ) async throws -> FeatureAuthoringOutcome? {
        if walk.refusedThisNight.contains(selected.name) {
            throw FeatureSelectionError.reselectedFeatureAlreadyRefused(selected.name)
        }
        let result = try await validateAndRecord(
            selected, scope: scope, reselectionDepth: walk.depth, context: context
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

    static func specificationSource(_ repositories: ProjectRepositories) throws -> ProjectSpecificationSource {
        switch repositories.specificationSourceLookup {
        case .none:
            throw FeatureSelectionError.noSpecificationSource
        case .multiple(let names):
            throw FeatureSelectionError.multipleSpecificationSources(names)
        case .resolved(let source):
            return source
        }
    }

    static func specificationMainline(
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
    ///
    /// `repairing` is the Operator's Todo on this Feature's halt (roadmap P22.5): the Feature was chosen by an
    /// earlier selection, so the forced-name check does not apply. `ignoringFaultBound` is set only for an
    /// `authoringRepeatedlyFaulted` halt, which is not re-halted on the very faults it was recorded for — the
    /// Todo is the intervention that halt waits for.
    func validateAndRecord(
        _ selected: SelectedFeature, scope: SelectionScope, reselectionDepth: Int, repairing: Bool = false,
        ignoringFaultBound: Bool = false, repairSnapshot: HaltRepairSnapshot? = nil, context: ActContext
    ) async throws -> FeatureAuthoringOutcome {
        let repositories = scope.repositories
        let candidates = scope.candidates
        if !repairing, let named = context.trigger.namedFeature, named != selected.name {
            throw FeatureSelectionError.namedFeatureIgnored(named: named, selected: selected.name)
        }
        if let refused = try refuseUnmergedReselection(selected, scope: scope, context: context) {
            return refused
        }
        let sortedRepositories = Set(selected.repositories).sorted()
        let checkpointed = SelectedFeature(
            name: selected.name, reasoning: selected.reasoning, sequence: selected.sequence,
            repositories: sortedRepositories, adoptedCardIssueIDs: selected.adoptedCardIssueIDs
        )
        if let cause = Self.haltCause(forRepositories: sortedRepositories, in: repositories) {
            return try await recordHalt(feature: selected.name, cause: cause, selection: checkpointed, context: context)
        }
        let holding = scope.held.filter { sortedRepositories.contains($0.consumer) }
        if let held = try recordReleaseGateHold(selected, holding: holding, context: context) {
            return held
        }

        let candidateIDs = Set(candidates.map(\.issueID))
        let adopted = Set(selected.adoptedCardIssueIDs).intersection(candidateIDs).sorted()
        let adoptedSet = Set(adopted)
        let unadopted = candidates.map(\.issueID).filter { !adoptedSet.contains($0) }.sorted()

        let validated = SelectedFeature(
            name: selected.name, reasoning: selected.reasoning, sequence: selected.sequence,
            repositories: sortedRepositories, adoptedCardIssueIDs: adopted
        )
        try recordSelected(validated, unadopted: unadopted, context: context)

        let faults = try context.journal.authoringFaultCount(feature: validated.name)
        if !ignoringFaultBound, !context.trigger.isForced, faults.count >= consecutiveAuthoringFaultsMax {
            return try await recordHalt(
                feature: validated.name,
                cause: .authoringRepeatedlyFaulted(count: faults.count, lastReason: faults.lastReason),
                selection: validated, context: context
            )
        }
        guard let transaction else {
            throw EngineInvocationError.notImplemented(.author)
        }
        guard let repairSnapshot else {
            return try await transaction.author(validated, reselectionDepth: reselectionDepth, context: context)
        }
        return try await transaction.authorRepaired(
            validated, snapshot: repairSnapshot, reselectionDepth: reselectionDepth, context: context
        )
    }

    private func recordSelected(_ validated: SelectedFeature, unadopted: [String], context: ActContext) throws {
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
    }

    /// Appends one `authoringReleaseGateHeld` per held consumer the selected Feature touches and returns
    /// ``FeatureAuthoringOutcome/releaseGateHeld``; nil when it touches none. Runs after the seam halt and
    /// before `.featureSelected` is recorded, so nothing is recorded as selected.
    func recordReleaseGateHold(
        _ selected: SelectedFeature, holding: [HeldConsumer], context: ActContext
    ) throws -> FeatureAuthoringOutcome? {
        guard !holding.isEmpty else { return nil }
        for edge in holding {
            try context.journal.append(
                .authoringReleaseGateHeld(
                    featureName: selected.name.rawValue, consumer: edge.consumer, producer: edge.producer,
                    producerFeatureIssueID: edge.producerFeatureIssueID, hold: edge.hold
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
        }
        return .releaseGateHeld
    }

    /// Why the selected `repositories` (sorted) cannot be authored: none were determined, one is outside this
    /// Project, or the Feature spans a declared Repo Dependency — checked in that order, before
    /// `.featureSelected` is recorded. Nil when authoring may go on.
    static func haltCause(
        forRepositories sorted: [String], in repositories: ProjectRepositories
    ) -> AuthoringHaltCause? {
        guard !sorted.isEmpty else { return .repositoriesUndetermined }
        if let outside = sorted.first(where: { repositories.workingRepo(named: $0) == nil }) {
            return .contractOutsideProject(repository: outside)
        }
        let spanning = spanningEdges(repositories.workingRepos, selected: sorted)
        return spanning.isEmpty ? nil : .featureSpansRepoDependency(edges: spanning)
    }

    /// The declared Repo Dependencies whose consumer and producer are both among the `selected` repositories,
    /// in the consumers' file order and then each consumer's edge order. Direct edges only: a consumer
    /// reading a producer that reads a third Repo is never chained.
    static func spanningEdges(_ repos: [Repo], selected: [String]) -> [SpannedRepoDependency] {
        let touched = Set(selected)
        return repos.filter { touched.contains($0.name) }.flatMap { consumer in
            consumer.consumes.filter { touched.contains($0.producer) }.map {
                SpannedRepoDependency(consumer: consumer.name, producer: $0.producer, via: $0.via)
            }
        }
    }

    /// Records a halt durably and routes it to Waiting on You, through the halt path
    /// ``AuthoringTransaction`` shares for the unreadable contract (roadmap P9.6).
    private func recordHalt(
        feature: FeatureName, cause: AuthoringHaltCause, selection: SelectedFeature?, context: ActContext
    ) async throws -> FeatureAuthoringOutcome {
        try await AuthoringHalt.record(feature: feature, cause: cause, selection: selection, context: context)
    }
}
