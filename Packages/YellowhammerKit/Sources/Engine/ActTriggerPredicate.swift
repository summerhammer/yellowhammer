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
    /// - build and land are exact complements over the in-flight Cycle's unfinished Cards; once the
    ///   Cycle has landed (roadmap P10.1; risks OQ8, once per Cycle), both are false regardless, so no
    ///   Repo Lane re-opens even if a Card returns to Todo.
    /// - the author trigger reads dispatchable Card states from the Journal, and the dispatch-time
    ///   Readiness Check (a later phase) is what refines which of those Cards actually dispatch —
    ///   do not mistake this for the Readiness Check.
    ///
    /// `nightID` and `runID` identify the invocation evaluating the predicate; only the author trigger reads
    /// them, to recognise the Night's first author firing. Without them no firing is the first.
    public static func evaluate(
        act: Act,
        trigger: ActTrigger,
        journal: JournalStore,
        nightID: Int64? = nil,
        runID: RunID? = nil
    ) throws -> ActTriggerOutcome {
        // Forced triggers always fire.
        if trigger.isForced {
            return .met
        }

        switch act {
        case .author:
            return try evaluateAuthor(journal: journal, nightID: nightID, runID: runID)
        case .build:
            return try evaluateBuild(journal: journal)
        case .land:
            return try evaluateLand(journal: journal)
        }
    }

    /// The author trigger (shift-scheduling/fire-an-act-on-schedule): met with no unarchived Cycle and no
    /// unfinished Card, or on the Night's first author firing.
    ///
    /// Lead decision, pending sponsor review: fire-an-act-on-schedule says to evaluate the trigger as false
    /// while a Feature is in flight, and select-the-next-feature says the pass that tests for merges runs
    /// every Night regardless of the in-flight skip. They are reconciled by letting the Night's first
    /// author firing through: it runs the clocks, the merge pass over the Unmerged Feature Stack and an
    /// in-flight Partial Landing, and the settle gesture, and `AuthorAct` itself skips authoring while a
    /// Feature is in flight. Every later firing of the Night is idle — with a Feature in flight it records
    /// `featureInFlight` and reads nothing from the board, because the Delta Read belongs to the Act's work.
    ///
    /// The first firing is the one with no other author `ActStarted` in this Night; the invocation has
    /// appended its own before this runs, so `runID` excludes it.
    private static func evaluateAuthor(
        journal: JournalStore, nightID: Int64?, runID: RunID?
    ) throws -> ActTriggerOutcome {
        let unfinished = try journal.unfinishedCardCount()
        let cycleInFlight = try journal.inFlightCycleID() != nil
        if !cycleInFlight, unfinished == 0 {
            return .met
        }
        if let nightID, let runID,
            try journal.authorActStartedCount(nightID: nightID, excludingRunID: runID) == 0 {
            return .met
        }
        return cycleInFlight ? .notMet(.featureInFlight) : .notMet(.unfinishedCardsPresent)
    }

    private static func evaluateBuild(journal: JournalStore) throws -> ActTriggerOutcome {
        guard let cycleID = try journal.inFlightCycleID() else {
            return .notMet(.noFeatureInFlight)
        }
        if try journal.isCycleLanded(cycleID: cycleID) {
            return .notMet(.cycleAlreadyLanded)
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
        if try journal.isCycleLanded(cycleID: cycleID) {
            return .notMet(.cycleAlreadyLanded)
        }
        let count = try journal.unfinishedCardCount(cycleID: cycleID)
        if count == 0 {
            return .met
        }
        return .notMet(.cycleHasUnfinishedCards)
    }
}
