import Domain
import Foundation
import Journal

/// Why the author Act's routed dispatch ended without a usable answer (roadmap P9.11): the Routing
/// Table had no candidate Route left, or a run crashed with no outcome attributable to its CLI. An
/// authoring fault (roadmap P9.10), never a halt: ``FeatureSelection`` and ``AuthoringTransaction`` catch
/// it, record it and end the Act as ``FeatureAuthoringOutcome/authoringRolledBack``.
public struct AuthoringDispatchFault: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String
    public let rejectedBreakdown: Bool

    public init(reason: String, rejectedBreakdown: Bool = false) {
        self.rejectedBreakdown = rejectedBreakdown
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
    /// local path). `instruction` composes the pass's instruction for the Route it is about to run on, given
    /// the invalid-output rejections of the Routes before it (`<route>: <rejection>`, in walk order) so the
    /// next Route learns why the last drafting was refused; a refusal, an exit or a timeout is no rejection of
    /// a drafting and is not among them. `accept` judges a completed result: a reason excludes the Route as
    /// invalid output, like a broken result contract, and the walk goes on. Throws
    /// ``AuthoringDispatchFault`` when no Route answered.
    func run(
        pass: RunPass, worktreePath: String, context: ActContext,
        additionalReadableDirectories: [String] = [],
        accept: (DispatchResult) async -> String? = { _ in nil },
        instruction: (Route, [String]) -> AuthoringInstruction
    ) async throws -> DispatchResult {
        var tried: Set<Route> = []
        var lastFailure: String?
        var earlierRejections: [String] = []
        var rejectedBreakdown = false
        var ordinal: Int64 = 0
        while true {
            let resolution = try resolve(tried: tried, context: context)
            guard case .resolved(let resolved) = resolution else {
                throw Self.exhausted(lastFailure: resolution.usageBackoffAccount ?? lastFailure,
                                     rejectedBreakdown: rejectedBreakdown)
            }
            let route = resolved.route
            ordinal += 1
            let dispatchRequest = AgentDispatchRequest(
                runID: context.runID, issueID: Self.runDirectoryName, attemptID: ordinal, route: route,
                pass: pass, instruction: .authoring(instruction(route, earlierRejections)), worktreePath: worktreePath,
                additionalReadableDirectories: additionalReadableDirectories
            )
            let judgement: Judgement
            do {
                let report = try await dispatch.dispatch(dispatchRequest)
                try record(report.origin, pass: pass, route: route, ordinal: Int(ordinal), context: context)
                if try context.recordUsageLimit(report.outcome, route: route) {
                    lastFailure = "\(route.cli) usage limit; authoring waits for CLI backoff"
                    continue
                }
                judgement = try await judge(report.outcome, pass: pass, route: route, accept: accept)
            } catch let refusal as AgentDispatchRefusal {
                judgement = .rejected(Rejection(
                    cause: .unavailable, reason: "\(refusal)",
                    lastFailure: "\(pass.rawValue) on \(route) is unavailable: \(refusal)"
                ))
            }
            switch judgement {
            case .answered(let result):
                return result
            case .rejected(let rejection):
                tried.insert(route)
                lastFailure = rejection.lastFailure
                rejectedBreakdown = rejectedBreakdown || rejection.producedBreakdown
                earlierRejections += rejection.draftingFeedback(route: route)
                try recordRejection(
                    .authoringRouteRejected(
                        pass: pass, route: route.description, ordinal: Int(ordinal), cause: rejection.cause,
                        reason: rejection.reason
                    ),
                    context: context
                )
            }
        }
    }

    private func resolve(tried: Set<Route>, context: ActContext) throws -> RouteResolution {
        try resolver.resolve(RouteRequest(kind: .authoring, repoRole: nil, excludedRoutes: tried),
                             backingOffCLIs: context.journal.backingOffCLIs())
    }

    private enum Judgement {
        case answered(DispatchResult)
        case rejected(Rejection)
    }

    /// One Route's failure: its cause class, the account recorded on its event, and the walk's last-failure text.
    private struct Rejection {
        let cause: AuthoringRouteRejectionCause
        let reason: String
        let lastFailure: String
        var producedBreakdown = false

        func draftingFeedback(route: Route) -> [String] {
            guard cause == .overDescriptionBudget || cause == .invalidOutput else { return [] }
            return ["`\(route)`: \(reason)"]
        }
    }

    /// Judges a Route's outcome: an answer `accept` takes, or the rejection that excludes the Route. A
    /// Crashed-Unknown run throws, ending authoring for this Act.
    private func judge(
        _ outcome: RunOutcome, pass: RunPass, route: Route, accept: (DispatchResult) async -> String?
    ) async throws -> Judgement {
        switch outcome {
        case .completed(let result):
            if let reason = result.authoringFailureReason {
                return .rejected(Rejection(
                    cause: .reportedFailed, reason: reason,
                    lastFailure: "\(pass.rawValue) on \(route) reported failed: \(reason)"
                ))
            }
            guard let rejection = await accept(result) else { return .answered(result) }
            let overBudget = rejection.contains(DescriptionBudgetOverrun.marker)
            return .rejected(Rejection(
                cause: overBudget ? .overDescriptionBudget : .invalidOutput, reason: rejection,
                lastFailure: "\(pass.rawValue) on \(route) returned invalid output: \(rejection)",
                producedBreakdown: Self.producedBreakdown(result)
            ))
        case .failed, .contractViolation, .timedOut:
            let account = Self.failureAccount(of: outcome, pass: pass, route: route) ?? ""
            return .rejected(Rejection(cause: Self.cause(of: outcome), reason: account, lastFailure: account))
        case .usageLimited:
            throw AuthoringDispatchFault(reason: "agent CLI usage limit; authoring deferred")
        case .crashedUnknown(let cause):
            throw AuthoringDispatchFault(
                reason: "\(pass.rawValue) on \(route) crashed with no outcome (\(cause)); a Crashed-Unknown "
                    + "run excludes no Route and ends authoring for this Act"
            )
        }
    }

    /// What a Route's non-answer says about it: an exit status, a broken result contract (#445) or the pass
    /// timeout (#507). Each is a capability failure that excludes the Route and falls through to the next.
    private static func failureAccount(of outcome: RunOutcome, pass: RunPass, route: Route) -> String? {
        switch outcome {
        case .failed(let exitStatus):
            "\(pass.rawValue) on \(route) exited with status \(exitStatus)"
        case .contractViolation(let error):
            "\(pass.rawValue) on \(route) broke the result contract: \(error)"
        case .timedOut(let after):
            "\(pass.rawValue) on \(route) ran out of time after \(after.wholeMinutes) min"
        case .completed, .crashedUnknown, .usageLimited:
            nil
        }
    }

    private static func cause(of outcome: RunOutcome) -> AuthoringRouteRejectionCause {
        switch outcome {
        case .contractViolation: .brokeResultContract
        case .timedOut: .timedOut
        case .failed, .completed, .crashedUnknown, .usageLimited: .exited
        }
    }

    private static func producedBreakdown(_ result: DispatchResult) -> Bool {
        if case .breakdown(let breakdown) = result, case .drafted = breakdown.outcome { return true }
        return false
    }

    private static func exhausted(lastFailure: String?, rejectedBreakdown: Bool) -> AuthoringDispatchFault {
        let table = "the Routing Table has no Route left for the authoring Kind"
        return AuthoringDispatchFault(
            reason: lastFailure.map { "\(table); last failure: \($0)" } ?? table,
            rejectedBreakdown: rejectedBreakdown
        )
    }

    private func recordRejection(_ event: JournalEvent, context: ActContext) throws {
        try context.journal.append(event, act: context.act, runID: context.runID, nightID: context.night.id)
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
