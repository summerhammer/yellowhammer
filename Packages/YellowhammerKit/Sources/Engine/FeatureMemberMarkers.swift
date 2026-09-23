import Domain
import Journal

/// A marker on a Cycle's member Card, derived at read time — nothing is written for it, no Card
/// attribute, no roll-up or count change (roadmap P11.3; spec: board-projection/maintain-the-managed-
/// block, second story). The roll-up block (roadmap P12.3, ``FeatureRollUpBlock``) renders these; this
/// is only the derivation it reads.
public enum FeatureMemberMarker: Hashable, Sendable {
    /// The Card has at least one banked reply and is still Waiting on You, or has been carried forward
    /// as Blocked after its Feature merged — an answer is recorded and waiting for opportunistic
    /// Adoption by a successor Feature (roadmap P11.5, joined at `AuthoringTransaction`/
    /// `AdoptionRevalidation`, `CardRun+Frame`'s dispatch payload, and here as a read-time marker).
    case bankedAnswer
    /// The Card is Cancelled.
    case cancelled
}

/// Derives ``FeatureMemberMarker``s for a Cycle's member Cards, keyed by Card id and containing only
/// Cards with at least one marker. Reads only; nothing it touches is written.
public enum FeatureMemberMarkers {
    public static func derive(cycleID: Int64, journal: JournalStore) throws -> [Int64: Set<FeatureMemberMarker>] {
        let bankedCardIDs = try journal.cardIDsWithBankedReplies(cycleID: cycleID)
        var markers: [Int64: Set<FeatureMemberMarker>] = [:]
        for card in try journal.cards(cycleID: cycleID) {
            var cardMarkers: Set<FeatureMemberMarker> = []
            if bankedCardIDs.contains(card.id), card.state == .waitingOnYou || card.state == .blocked {
                cardMarkers.insert(.bankedAnswer)
            }
            if card.state == .cancelled {
                cardMarkers.insert(.cancelled)
            }
            if !cardMarkers.isEmpty {
                markers[card.id] = cardMarkers
            }
        }
        return markers
    }
}
