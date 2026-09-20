/// Why an Act fired but did nothing: its trigger predicate was false.
///
/// Firing is not the same as doing work. Every firing evaluates its own Act's trigger and exits
/// quietly when it is not met, and this is the reason it records in the Journal on the way out —
/// what the Night Summary reads to say why a Night was quiet.
public enum ActIdleReason: String, CaseIterable, Sendable {
    /// author: the Project still holds Cards left to work, so there is nothing to author.
    case unfinishedCardsPresent = "unfinished_cards_present"
    /// build and land: no Feature is in flight, so there is no Cycle to build or land.
    case noFeatureInFlight = "no_feature_in_flight"
    /// build: the in-flight Cycle has nothing left to build. Nothing *stops* build after land —
    /// its trigger is simply false.
    case cycleHasNoUnfinishedCards = "cycle_has_no_unfinished_cards"
    /// land: the in-flight Cycle still has unfinished Cards, so it is not ready to land.
    case cycleHasUnfinishedCards = "cycle_has_unfinished_cards"
    /// build and land: the in-flight Cycle has already landed once (roadmap P10.1; risks OQ8, once per
    /// Cycle). Checked before either Act's unfinished-Card count, so a Card returning to Todo after
    /// landing never re-opens a Repo Lane.
    case cycleAlreadyLanded = "cycle_already_landed"
}
