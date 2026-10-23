import Domain
import Journal

// OQ182 item 6 (with item 8.3): a later member of a same-repository sequence is adopted only when every
// earlier member of its old lane is Done with an Observed Merge of the old Feature in that repository, or
// is adopted ahead of it into the same successor Feature this same pass. Split out of
// AdoptionRevalidation.swift to keep that file's body under the SwiftLint length limit.

extension AdoptionRevalidation {
    /// `selection.adoptedCardIssueIDs`, fetched and sorted by old Cycle, repository and old authored
    /// order (spec ruling OQ182, item 6, step 2): the order the sequence gate must process candidates
    /// in, so an earlier member that is itself a candidate this same pass is already decided (kept or
    /// not) by the time a later one asks about it.
    static func sortedCandidates(_ issueIDs: [String], journal: JournalStore) throws -> [CardRecord] {
        let cards = try issueIDs.map { issueID -> CardRecord in
            guard let card = try journal.card(issueID: issueID) else {
                throw AuthoringTransactionError.adoptedCardUnknown(issueID: issueID)
            }
            return card
        }
        return cards.sorted {
            ($0.cycleID, $0.repository, $0.authoredOrder) < ($1.cycleID, $1.repository, $1.authoredOrder)
        }
    }

    /// Every earlier member of `card`'s same-repository sequence in its old lane (``RepoLane/derive(from:adoptedFrom:)``,
    /// ``RepoLane/sequencePredecessors(of:)``) that meets neither OQ182 condition — empty when `card`
    /// has none, or every one of them qualifies (a first sequence member, or a Card from an adopted
    /// sequence of the old Feature with no earlier member of its own, is never affected). `kept` is this
    /// pass's own narrowed, growing selection (never the raw `selection.adoptedCardIssueIDs`): a
    /// predecessor that is itself a candidate this pass only counts once it has actually been kept.
    static func absentEarlierSequenceMembers(
        of card: CardRecord, oldCycleID: Int64, journal: JournalStore, kept: [String]
    ) throws -> [AbsentEarlierSequenceMember] {
        guard let oldFeature = try journal.feature(cycleID: oldCycleID) else { return [] }
        let siblings = try journal.cards(cycleID: oldCycleID)
        // A Card that has since left the old Feature is no longer among `siblings`: it is read live and
        // repositioned at the old order its departure recorded (spec ruling OQ182, item 6, step 1).
        let departed = try journal.cardsAdoptedAway(fromFeatureIssueID: oldFeature.issueID)
        let adoptedFrom = try journal.adoptionOrigins(featureIssueID: oldFeature.issueID)

        let lanes = RepoLane.derive(from: siblings + departed, adoptedFrom: adoptedFrom)
        guard let lane = lanes.first(where: { $0.repository == card.repository }) else { return [] }

        let landings = try journal.landings(featureID: oldFeature.id)
        let keptIssueIDs = Set(kept)
        var absent: [AbsentEarlierSequenceMember] = []
        for predecessor in lane.sequencePredecessors(of: card) {
            // No longer in this old Cycle: it left for a different Feature (this one is brand new, so
            // it cannot be that one) — it never meets either condition.
            if predecessor.cycleID != oldCycleID {
                absent.append(
                    AbsentEarlierSequenceMember(title: predecessor.displayTitle, repository: predecessor.repository)
                )
                continue
            }
            let landed = landings[predecessor.repository] != nil
            if predecessor.state == .done, !predecessor.isRemovedFromBoard, landed { continue }
            if keptIssueIDs.contains(predecessor.issueID) { continue }
            absent.append(
                AbsentEarlierSequenceMember(title: predecessor.displayTitle, repository: predecessor.repository)
            )
        }
        return absent
    }
}
