/// Why an Act fired but did nothing: its trigger predicate was false.
///
/// Firing is not the same as doing work. Every firing evaluates its own Act's trigger and exits
/// quietly when it is not met, and this is the reason it records in the Journal on the way out —
/// what the Night Summary reads to say why a Night was quiet.
public enum ActIdleReason: String, CaseIterable, Sendable {
    /// author: the Project still holds Cards left to work, so there is nothing to author.
    case unfinishedCardsPresent = "unfinished_cards_present"
    /// author: a Feature is in flight (an unarchived Cycle, or Cards left to work) and this is not the
    /// Night's first author firing. Only that opening firing runs while a Feature is in flight; every
    /// later periodic firing exits quietly until the land Act archives the Cycle.
    case featureInFlight = "feature_in_flight"
    /// build and land: no Feature is in flight, so there is no Cycle to build or land.
    case noFeatureInFlight = "no_feature_in_flight"
    /// build: the in-flight Cycle has nothing left to build. Nothing *stops* build after land —
    /// its trigger is simply false.
    case cycleHasNoUnfinishedCards = "cycle_has_no_unfinished_cards"
    /// land: the in-flight Cycle still has unfinished Cards, so it is not ready to land.
    case cycleHasUnfinishedCards = "cycle_has_unfinished_cards"
    /// build and land: the in-flight Cycle has landed and Verification returned its Feature to the
    /// Operator (spec: verification/return-a-feature-with-unmet-clauses). Landing is not reversed by a
    /// failed verification, so nothing is left to build or land; the Feature stays in flight, unarchived,
    /// until the Operator decides. Recorded in place of ``cycleAlreadyLanded`` so the Journal names the
    /// Feature's state, not only the Cycle's (issue #695).
    case featureReturned = "feature_returned"
    /// build and land: the in-flight Cycle has already landed once (roadmap P10.1; risks OQ8, once per
    /// Cycle) and its Feature was not returned (e.g. an all-met verdict at N = 0, which lands without
    /// archiving). Checked before either Act's unfinished-Card count, so a Card returning to Todo after
    /// landing never re-opens a Repo Lane.
    case cycleAlreadyLanded = "cycle_already_landed"
    case waitingForAnswer = "waiting_for_answer"
    case handoffBegun = "handoff_begun"
}
