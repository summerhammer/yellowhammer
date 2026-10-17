import Domain

extension ActContext {
    /// Record account availability without making a capability judgement about the Route.
    func recordUsageLimit(_ outcome: RunOutcome, route: Route) throws -> Bool {
        guard case .usageLimited(let hint) = outcome else { return false }
        try journal.recordUsageLimit(route: route, resetHint: hint, runID: runID, act: act, nightID: night.id)
        return true
    }
}
