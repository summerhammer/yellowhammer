import Domain
import Journal

extension PulseSnapshot {
    /// The Feature's Roll-up word, from the same inputs Engine's `FeatureRollUpMaintenance.maintain` reads
    /// (reimplemented because Pulse may not import Engine). A Feature with a Cycle is past the zero-Card
    /// standings, so no Cards reads `authoring`; every Card Shelved reads nil.
    static func rollupState(
        _ journal: JournalStore,
        inFlight: (feature: FeatureRecord, cycleID: Int64),
        cards: [CardRecord],
        landings: [String: String],
        verification: FeatureVerificationRecord?
    ) throws -> RollUpState? {
        guard !cards.isEmpty else { return .authoring }
        let live = cards.map(\.state).filter { $0 != .shelved }
        guard !live.isEmpty else { return nil }
        // N, not the touched repositories: a repository with a No-Pushed-Branch Outcome has no Feature Branch.
        let pushed = try journal.pushedRepositories(featureID: inFlight.feature.id)
        let unmetCount = verification.map { record in
            record.clauses.count { $0.verdict == .unmet || $0.verdict == .unresolved }
        }
        let notCheckedCount = verification?.clauses.count { $0.verdict == .notChecked } ?? 0
        return RollUpLattice.rollUp(
            liveCardStates: live,
            lanesPushed: try journal.isCycleLanded(cycleID: inFlight.cycleID),
            verificationPassed: verification?.clauses.allSatisfy { $0.verdict == .met } ?? false,
            unmetClauseCount: unmetCount,
            notCheckedClauseCount: notCheckedCount,
            mergedFraction: MergedFraction(
                mergedCount: Set(landings.keys).intersection(pushed).count, totalCount: pushed.count
            )
        ).state
    }
}
