import Domain
import Foundation
import Journal

/// What one Route Pre-flight came to (OQ126).
public enum RoutePreflightVerdict: Equatable, Sendable {
    /// The CLI accepted the Route's model and effort. `answeredBy` is set when something other than
    /// the CLI answered — a rehearsal fixture — and is recorded with the verdict.
    case passed(answeredBy: String? = nil)
    /// The CLI refused the Route, or could not be run on it; `reason` is Operator-facing, e.g. what the
    /// CLI printed when it rejected the model.
    case failed(reason: String)
}

/// The Route Pre-flight seam (OQ126): runs a Route's CLI once with that Route's model and effort on a
/// trivial prompt. It is the Probe idea applied to a whole Route — the Probe establishes that a CLI
/// works, the pre-flight that it accepts that model and effort — and nothing else can check it,
/// because a Card override is set in Linear and Yellowhammer knows no CLI's model list. An
/// implementation translates and never decides; any thrown error is an engine fault.
public protocol RoutePreflighting: Sendable {
    func preflight(_ route: Route, runID: RunID) async throws -> RoutePreflightVerdict
}

/// The pre-flight a Rehearsal Night runs: it never spawns anything (a rehearsal Night never dispatches
/// an agent CLI) and passes every Route as a fixture answer, so the rest of the Readiness Check runs as
/// it would on a real Night.
public struct RehearsalRoutePreflight: RoutePreflighting {
    public init() {}

    public func preflight(_ route: Route, runID: RunID) async throws -> RoutePreflightVerdict {
        .passed(answeredBy: "rehearsal fixture: no agent CLI was run")
    }
}

/// Every Card override's Route passes its Route Pre-flight before dispatch, in the build Act's
/// Readiness Check (OQ126). A Route's verdict is cached for the rest of the Night in the Journal, as a
/// `RoutePreflightRan` event stamped with the Night, so Cards pinned to the same Route share one
/// pre-flight across Acts. Within one invocation, Cards in concurrent Repo Lanes asking about the same
/// Route at once share one run too.
///
/// One per invocation, shared by every Card run in it; it holds nothing beyond the runs in flight.
public actor RoutePreflight {
    private let preflighting: any RoutePreflighting
    private var inFlight: [Route: Task<RoutePreflightVerdict, any Error>] = [:]

    public init(_ preflighting: any RoutePreflighting) {
        self.preflighting = preflighting
    }

    /// The Route's verdict for this Night: the one the Journal already holds, or a fresh pre-flight
    /// recorded there. Without a Night the verdict is not cached across Acts.
    public func verdict(
        for route: Route, journal: JournalStore, runID: RunID, act: Act, nightID: Int64?
    ) async throws -> RoutePreflightVerdict {
        if let running = inFlight[route] {
            return try await running.value
        }
        let preflighting = preflighting
        let task = Task {
            if let nightID, let cached = try Self.cachedVerdict(for: route, nightID: nightID, journal: journal) {
                return cached
            }
            let verdict = try await preflighting.preflight(route, runID: runID)
            try journal.append(Self.event(route: route, verdict: verdict), act: act, runID: runID, nightID: nightID)
            return verdict
        }
        inFlight[route] = task
        defer { inFlight[route] = nil }
        return try await task.value
    }

    /// The latest `RoutePreflightRan` verdict for `route` this Night; nil when none ran yet.
    static func cachedVerdict(
        for route: Route, nightID: Int64, journal: JournalStore
    ) throws -> RoutePreflightVerdict? {
        let records = try journal.events(ofType: .routePreflightRan).filter { $0.nightID == nightID }
        for record in records.reversed() {
            guard case .routePreflightRan(route, let passed, let reason) = record.event else { continue }
            return passed ? .passed(answeredBy: reason) : .failed(reason: reason ?? "no reason recorded")
        }
        return nil
    }

    static func event(route: Route, verdict: RoutePreflightVerdict) -> JournalEvent {
        switch verdict {
        case .passed(let answeredBy):
            .routePreflightRan(route: route, passed: true, reason: answeredBy)
        case .failed(let reason):
            .routePreflightRan(route: route, passed: false, reason: reason)
        }
    }
}
