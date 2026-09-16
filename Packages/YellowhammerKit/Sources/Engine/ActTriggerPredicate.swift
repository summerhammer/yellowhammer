import Domain
import Foundation
import Journal

/// The outcome of evaluating an Act's trigger predicate.
public enum ActTriggerOutcome: Equatable, Sendable {
    case met
    case notMet(ActIdleReason)
}

/// Evaluates whether an Act should run based on its trigger and the Journal's state.
///
/// The predicate is evaluated inside a firing Project, from that Project's Journal alone. When the
/// predicate is false the Act records an idle tick in the Journal and exits 0, writing nothing else.
public enum ActTriggerPredicate {
    /// Evaluates the predicate for the given Act's trigger.
    ///
    /// The two key judgements:
    /// - build and land are exact complements over the in-flight Cycle, which is why nothing needs
    ///   to *stop* build after land — its trigger is simply false.
    /// - the author trigger reads dispatchable Card states from the Journal, and the dispatch-time
    ///   Readiness Check (a later phase) is what refines which of those Cards actually dispatch —
    ///   do not mistake this for the Readiness Check.
    public static func evaluate(
        act: Act,
        trigger: ActTrigger,
        journal: JournalStore
    ) throws -> ActTriggerOutcome {
        // Forced triggers always fire.
        if trigger.isForced {
            return .met
        }

        switch act {
        case .author:
            return try evaluateAuthor(journal: journal)
        case .build:
            return try evaluateBuild(journal: journal)
        case .land:
            return try evaluateLand(journal: journal)
        }
    }

    private static func evaluateAuthor(journal: JournalStore) throws -> ActTriggerOutcome {
        let count = try journal.unfinishedCardCount()
        if count == 0 {
            return .met
        }
        return .notMet(.unfinishedCardsPresent)
    }

    private static func evaluateBuild(journal: JournalStore) throws -> ActTriggerOutcome {
        guard let cycleID = try journal.inFlightCycleID() else {
            return .notMet(.noFeatureInFlight)
        }
        let count = try journal.unfinishedCardCount(cycleID: cycleID)
        if count > 0 {
            return .met
        }
        return .notMet(.cycleHasNoUnfinishedCards)
    }

    private static func evaluateLand(journal: JournalStore) throws -> ActTriggerOutcome {
        guard let cycleID = try journal.inFlightCycleID() else {
            return .notMet(.noFeatureInFlight)
        }
        let count = try journal.unfinishedCardCount(cycleID: cycleID)
        if count == 0 {
            return .met
        }
        return .notMet(.cycleHasUnfinishedCards)
    }
}
