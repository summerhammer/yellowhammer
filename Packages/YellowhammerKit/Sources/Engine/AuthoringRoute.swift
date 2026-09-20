import Domain
import Foundation
import Journal

/// Why the author Act's routed dispatch ended without a usable answer (roadmap P9.11): the Routing
/// Table had no candidate Route left, or a run crashed with no outcome attributable to its CLI. An
/// authoring fault (roadmap P9.10), never a halt: ``FeatureSelection`` and ``AuthoringTransaction`` catch
/// it, record it and end the Act as ``FeatureAuthoringOutcome/authoringRolledBack``.
public struct AuthoringDispatchFault: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// The one routed-dispatch path both author Act passes use (roadmap P9.11; spec: routing overview, "the
/// author Act routes through the same table"). It resolves under the reserved ``Kind/authoring`` with no
/// Repo Role through the ordinary ``RouteResolver`` — key shape, merge rule and resolution unchanged —
/// and dispatches the resolved Route as an agent CLI.
///
/// The entry's configured fallback order is walked by the resolver itself: a capability failure of a
/// Route (a refusal, a non-zero exit, or a completed result whose outcome is `failed`) adds it to the
/// excluded set and resolves again. A Crashed-Unknown run excludes nothing and ends authoring for this
/// Act, as does an exhausted table. At most one dispatch is made per candidate Route.
public struct AuthoringRoute: Sendable {
    /// The specification-source-relative run directory name every authoring request carries.
    public static let runDirectoryName = "authoring"

    public let resolver: RouteResolver
    public let dispatch: any AgentDispatch

    public init(resolver: RouteResolver, dispatch: any AgentDispatch) {
        self.resolver = resolver
        self.dispatch = dispatch
    }

    /// Dispatches `pass` on the first Route that answers, in `worktreePath` (the specification source's
    /// local path). `instruction` composes the pass's instruction for the Route it is about to run on.
    /// Throws ``AuthoringDispatchFault`` when no Route answered.
    func run(
        pass: RunPass, worktreePath: String, context: ActContext,
        instruction: (Route) -> AuthoringInstruction
    ) async throws -> DispatchResult {
        var tried: Set<Route> = []
        var lastFailure: String?
        var ordinal: Int64 = 0
        while true {
            let request = RouteRequest(kind: .authoring, repoRole: nil, override: .none, excludedRoutes: tried)
            guard case .resolved(let resolved) = try resolver.resolve(request) else {
                let table = "the Routing Table has no Route left for the authoring Kind"
                throw AuthoringDispatchFault(reason: lastFailure.map { "\(table); last failure: \($0)" } ?? table)
            }
            let route = resolved.route
            ordinal += 1
            let dispatchRequest = AgentDispatchRequest(
                runID: context.runID, issueID: Self.runDirectoryName, attemptID: ordinal, route: route,
                pass: pass, instruction: .authoring(instruction(route)), worktreePath: worktreePath
            )
            let report: AgentDispatchReport
            do {
                report = try await dispatch.dispatch(dispatchRequest)
            } catch let refusal as AgentDispatchRefusal {
                tried.insert(route)
                lastFailure = "\(pass.rawValue) on \(route) is unavailable: \(refusal)"
                continue
            }
            try record(report.origin, pass: pass, route: route, ordinal: Int(ordinal), context: context)
            switch report.outcome {
            case .completed(let result):
                guard let reason = result.authoringFailureReason else { return result }
                tried.insert(route)
                lastFailure = "\(pass.rawValue) on \(route) reported failed: \(reason)"
            case .failed(let exitStatus):
                tried.insert(route)
                lastFailure = "\(pass.rawValue) on \(route) exited with status \(exitStatus)"
            case .crashedUnknown(let cause):
                throw AuthoringDispatchFault(
                    reason: "\(pass.rawValue) on \(route) crashed with no outcome (\(cause)); a Crashed-Unknown "
                        + "run excludes no Route and ends authoring for this Act"
                )
            }
        }
    }

    private func record(
        _ origin: AgentDispatchOrigin, pass: RunPass, route: Route, ordinal: Int, context: ActContext
    ) throws {
        let fixture: String?
        switch origin {
        case .agentCLIProcess: fixture = nil
        case .rehearsalFixture(let name): fixture = name
        }
        try context.journal.append(
            .authoringDispatched(pass: pass, route: route.description, ordinal: ordinal, fixture: fixture),
            act: context.act, runID: context.runID, nightID: context.night.id
        )
    }
}
