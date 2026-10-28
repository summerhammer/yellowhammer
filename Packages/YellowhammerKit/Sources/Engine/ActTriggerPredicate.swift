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
    /// - build and land are exact complements over the in-flight Cycle's unfinished, unheld Cards: a
    ///   held Todo Card (``RepoLane/heldCards(in:where:adoptedFrom:currentCard:)``, spec ruling OQ182 item 4)
    ///   counts as finished for both, so a Cycle with no runnable Card lands even while a held Card
    ///   stays Todo. Once the Cycle has landed (roadmap P10.1; risks OQ8, once per Cycle), both are
    ///   false regardless, so no Repo Lane re-opens even if a Card returns to Todo.
    /// - the author trigger reads dispatchable Card states from the Journal, and the dispatch-time
    ///   Readiness Check (a later phase) is what refines which of those Cards actually dispatch —
    ///   do not mistake this for the Readiness Check.
    ///
    /// `nightID` and `runID` identify this firing and its hold evidence. The optional firing grid
    /// is supplied by EngineCommand for production; callers without a grid retain state-only triggers.
    public static func evaluate(
        act: Act,
        trigger: ActTrigger,
        journal: JournalStore,
        nightID: Int64,
        runID: RunID,
        landHoldSchedule: LandHoldSchedule? = nil,
        now: Date = Date()
    ) throws -> ActTriggerOutcome {
        let holding = try LandHold.refresh(journal: journal, nightID: nightID, runID: runID,
                                           schedule: landHoldSchedule, now: now)
        if act == .land, let cycleID = try journal.inFlightCycleID() {
            if let schedule = landHoldSchedule, now >= schedule.end {
                try journal.endNightHold(nightID: nightID, runID: runID, now: now)
            } else if trigger.isForced {
                try journal.endLandHold(cycleID: cycleID, reason: "forced land", runID: runID, now: now)
            }
        }
        // Forced triggers always fire.
        if trigger.isForced {
            return .met
        }

        switch act {
        case .author:
            return try evaluateAuthor(journal: journal, nightID: nightID, runID: runID)
        case .build:
            return try evaluateBuild(journal: journal, holding: holding)
        case .land:
            return try evaluateLand(
                journal: journal, holding: holding && !(landHoldSchedule.map { now >= $0.end } ?? false),
                runID: runID, now: now
            )
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
        journal: JournalStore, nightID: Int64, runID: RunID
    ) throws -> ActTriggerOutcome {
        let unfinished = try journal.unfinishedCardCount()
        let cycleInFlight = try journal.inFlightCycleID() != nil
        if !cycleInFlight, unfinished == 0 {
            return .met
        }
        if try journal.authorActStartedCount(nightID: nightID, excludingRunID: runID) == 0 {
            return .met
        }
        if let cycleID = try journal.inFlightCycleID(), try journal.isCycleLanded(cycleID: cycleID) {
            return .met
        }
        return cycleInFlight ? .notMet(.featureInFlight) : .notMet(.unfinishedCardsPresent)
    }

    private static func evaluateBuild(journal: JournalStore, holding: Bool) throws -> ActTriggerOutcome {
        guard let cycleID = try journal.inFlightCycleID() else {
            return .notMet(.noFeatureInFlight)
        }
        if try journal.isCycleLanded(cycleID: cycleID) {
            return .notMet(.cycleAlreadyLanded)
        }
        if try journal.hasCycleHandoffBegun(cycleID: cycleID) { return .notMet(.handoffBegun) }
        let count = try unfinishedUnheldCardCount(cycleID: cycleID, journal: journal)
        if count > 0 || holding {
            return .met
        }
        return .notMet(.cycleHasNoUnfinishedCards)
    }

    private static func evaluateLand(
        journal: JournalStore, holding: Bool, runID: RunID, now: Date
    ) throws -> ActTriggerOutcome {
        guard let cycleID = try journal.inFlightCycleID() else {
            return .notMet(.noFeatureInFlight)
        }
        if try journal.isCycleLanded(cycleID: cycleID) {
            return .notMet(.cycleAlreadyLanded)
        }
        if try journal.hasCycleHandoffBegun(cycleID: cycleID) { return .met }
        let count = try unfinishedUnheldCardCount(cycleID: cycleID, journal: journal)
        if count == 0 {
            if holding, try !LandHold.canEnd(journal: journal, cycleID: cycleID, now: now) {
                return .notMet(.waitingForAnswer)
            }
            try journal.endLandHold(cycleID: cycleID, reason: "ran out", runID: runID, now: now)
            return .met
        }
        return .notMet(.cycleHasUnfinishedCards)
    }

    /// `journal.unfinishedCardCount(cycleID:)`, less the Cycle's held Work Cards (spec ruling OQ182,
    /// item 4): a held Todo Card is not dispatchable, so it no longer keeps build met or land unmet —
    /// only a runnable Card does. The Journal module cannot see `RepoLane`, so the subtraction happens
    /// here, from the Feature's own adoption origins and current Cards. `cycleID` is in flight, so its
    /// Feature must resolve; a miss means the Journal is inconsistent, and `journal.feature(cycleID:)`
    /// already names that case as nil rather than guessing.
    private static func unfinishedUnheldCardCount(cycleID: Int64, journal: JournalStore) throws -> Int {
        let unfinished = try journal.unfinishedCardCount(cycleID: cycleID)
        guard let feature = try journal.feature(cycleID: cycleID) else {
            throw JournalError.cycleUnknown(cycleID: cycleID)
        }
        let cards = try journal.cards(cycleID: cycleID)
        let adoptedFrom = try journal.adoptionOrigins(featureIssueID: feature.issueID)
        let held = try RepoLane.heldCards(in: cards, adoptedFrom: adoptedFrom) { try journal.card(id: $0.id) }
        return unfinished - held.count
    }
}
