import Domain
import Journal

/// The Work Card a held Card is named as waiting on in a closure comment (spec ruling 2026-10-22, item
/// 8.4): a comment identifies Cards by issue id, as every other line of these comments does, but also
/// carries the display title so the line reads as prose.
public struct HeldWorkCard: Equatable, Sendable {
    public let issueID: String
    public let title: String

    public init(issueID: String, title: String) {
        self.issueID = issueID
        self.title = title
    }
}

/// Pairs each Blocked Work Card a Feature's close left behind a same-repository sequence predecessor
/// with that predecessor (spec ruling 2026-10-22, item 8.4): read after the close's own auto-Block has
/// already run (``CardAutoBlock/held(cycleID:featureIssueID:reason:context:)`` at merge close;
/// ``CardAutoBlock/releasedActive(cycleID:reason:context:)`` at native Done and cancellation), so the
/// three closure comments (``FeatureMergeClosureComment``, ``FeatureCompletionComment``,
/// ``FeatureReleaseComment``) can name what each held Card waits on. Recomputed from Journal state, so a
/// retried pass, which finds the same Cards already Blocked, pairs the same two.
///
/// A carried-forward Card is named held only when its Block Reason is `feature completed` or
/// `feature abandoned` — the reasons a close itself gives a held Card — and
/// ``RepoLane/holder(of:currentCard:)`` still names an earlier, not-Done member of its sequence. A Card
/// already Blocked before the close (for example `authoring defect` or `reply overdue`) keeps its own
/// reason and is never named held, whatever its own sequence predecessor's state. Lanes are derived from
/// every Card of the Cycle, removed ones included, so a removed predecessor still holds (OQ142); a
/// removed Card is never itself returned.
enum HeldWorkCards {
    static func pairs(
        cycleID: Int64, featureIssueID: String, journal: JournalStore
    ) throws -> [(card: CardRecord, holder: CardRecord)] {
        let cards = try journal.cards(cycleID: cycleID)
        let adoptedFrom = try journal.adoptionOrigins(featureIssueID: featureIssueID)
        return try RepoLane.heldCards(
            in: cards, where: { $0.state == .blocked && !$0.isRemovedFromBoard && isHeldReason($0.blockReason) },
            adoptedFrom: adoptedFrom, currentCard: { try journal.card(id: $0.id) }
        )
    }

    private static func isHeldReason(_ raw: String?) -> Bool {
        guard let raw, let reason = BlockReason(rawValue: raw) else { return false }
        return reason == .featureCompleted || reason == .featureAbandoned
    }
}
