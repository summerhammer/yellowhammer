import Domain
import Foundation

/// The model-authored selection (roadmap P9.11), dispatched as an agent CLI through ``AuthoringRoute``:
/// composes the ``AuthoringInstruction``, runs it on the routed Route and maps the decoded result onto
/// ``FeatureSelectionOutcome``. It judges nothing itself.
public struct RoutedFeatureSelector: FeatureSelecting {
    public let route: AuthoringRoute

    public init(route: AuthoringRoute) {
        self.route = route
    }

    public func select(
        _ request: FeatureSelectionRequest, context: ActContext
    ) async throws -> FeatureSelectionOutcome {
        let result = try await route.run(
            pass: .selection, worktreePath: request.specificationSource.path, context: context
        ) { route in
            AuthoringInstruction(
                pass: .selection, route: route, specificationSource: request.specificationSource,
                specificationMainline: request.specificationMainline, repos: request.repos,
                mainlines: request.mainlines, namedFeature: request.namedFeature,
                adoptionCandidates: request.adoptionCandidates, selectedFeature: nil, resultFilePath: ""
            )
        }
        guard case .selection(let selection) = result, let outcome = selection.featureSelectionOutcome else {
            preconditionFailure("a routed selection returns only a completed selection result")
        }
        return outcome
    }
}

/// The model-authored breakdown (roadmap P9.11), dispatched as an agent CLI through ``AuthoringRoute``.
public struct RoutedFeatureBreakdown: FeatureBreakdownDrafting {
    public let route: AuthoringRoute

    public init(route: AuthoringRoute) {
        self.route = route
    }

    public func breakdown(
        for selection: SelectedFeature, mainlines: ResolvedMainlines, context: ActContext
    ) async throws -> FeatureBreakdown {
        guard let repositories = context.repositories,
            case .resolved(let source) = repositories.specificationSourceLookup
        else {
            throw AuthoringDispatchFault(reason: "this Project has no single specification source to break down")
        }
        let specificationMainline: ResolvedMainline?
        switch source {
        case .specSource: specificationMainline = mainlines.specSource
        case .workingRepo(let repo): specificationMainline = mainlines[repo]
        }
        let result = try await route.run(pass: .breakdown, worktreePath: source.path, context: context) { route in
            AuthoringInstruction(
                pass: .breakdown, route: route, specificationSource: source,
                specificationMainline: specificationMainline, repos: repositories.workingRepos,
                mainlines: mainlines, namedFeature: context.trigger.namedFeature, adoptionCandidates: [],
                selectedFeature: selection, resultFilePath: ""
            )
        }
        guard case .breakdown(let breakdown) = result, case .drafted(let drafted) = breakdown.outcome else {
            preconditionFailure("a routed breakdown returns only a completed, drafted result")
        }
        return drafted
    }
}
