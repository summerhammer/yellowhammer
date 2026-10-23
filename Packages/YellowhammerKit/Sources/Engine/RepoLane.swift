import Domain
import Journal

/// The Cards of one Feature belonging to one Repo, in authored order (glossary → Repo Lane). Derived
/// from the Cards' repository labels on every build Act, never stored.
public struct RepoLane: Equatable, Sendable {
    public let repository: String
    /// Every Card of the lane, in authored order, all states.
    public let cards: [CardRecord]
    /// Every adopted Card of the lane, mapped to the Feature Issue it was adopted from (spec ruling
    /// OQ182, item 5): read once per build Act from the recorded `CardAdopted` events
    /// (``JournalStore/adoptionOrigins(featureIssueID:)``), never stored by this lane.
    public let adoptedFrom: [Int64: String]

    public init(repository: String, cards: [CardRecord], adoptedFrom: [Int64: String] = [:]) {
        self.repository = repository
        self.cards = cards
        self.adoptedFrom = adoptedFrom
    }

    /// The Cards this lane still has to run: Todo only, and never a removed one (trashed, or archived
    /// while in play; OQ142) — it is set aside, not work.
    public var runnable: [CardRecord] {
        cards.filter { $0.state == .todo && !$0.isRemovedFromBoard }
    }

    /// Groups `cards` into Repo Lanes: one lane per repository, ordered by repository name, each
    /// lane's Cards in the order they were authored.
    public static func derive(from cards: [CardRecord], adoptedFrom: [Int64: String] = [:]) -> [RepoLane] {
        var byRepository: [String: [CardRecord]] = [:]
        for card in cards {
            byRepository[card.repository, default: []].append(card)
        }
        return byRepository.keys.sorted().map { repository in
            let cards = byRepository[repository]!.sorted { $0.authoredOrder < $1.authoredOrder }
            return RepoLane(repository: repository, cards: cards, adoptedFrom: adoptedFrom)
        }
    }

    /// The same-repository sequence `card` belongs to (spec ruling OQ182, items 2 and 5): every newly
    /// authored Card of the lane (``adoptedFrom`` holds no entry for it) belongs to one sequence; an
    /// adopted Card belongs to the sequence of the Cards adopted from the same previous Feature.
    private enum SequenceKey: Hashable {
        case newlyAuthored
        case adopted(String)
    }

    private func sequenceKey(for card: CardRecord) -> SequenceKey {
        if let origin = adoptedFrom[card.id] {
            return .adopted(origin)
        }
        return .newlyAuthored
    }

    /// The earlier Cards of `card`'s own same-repository sequence, in authored order (spec ruling OQ182,
    /// item 2): an adopted Card is never a newly authored Card's predecessor, and vice versa.
    public func sequencePredecessors(of card: CardRecord) -> [CardRecord] {
        let key = sequenceKey(for: card)
        return cards
            .filter { sequenceKey(for: $0) == key && $0.authoredOrder < card.authoredOrder }
            .sorted { $0.authoredOrder < $1.authoredOrder }
    }

    /// The first sequence predecessor of `card` whose current record — read through `currentCard`,
    /// never trusted from this lane's own stale snapshot — is not Done; nil when `card` is not held
    /// (spec ruling OQ182, item 2). A predecessor removed from the board (OQ142) holds too, whatever
    /// state it stood in when it was set aside.
    public func holder(
        of card: CardRecord, currentCard: (CardRecord) throws -> CardRecord
    ) rethrows -> CardRecord? {
        for predecessor in sequencePredecessors(of: card) {
            let current = try currentCard(predecessor)
            if current.state != .done || current.isRemovedFromBoard {
                return current
            }
        }
        return nil
    }

    /// Every Work Card of `cards` considered by `isConsidered`, held behind a not-Done same-repository
    /// sequence predecessor, paired with that predecessor (spec ruling OQ182, item 4; spec ruling
    /// 2026-10-22, item 8.4): the land trigger (``ActTriggerPredicate``), the Partial Landing pull
    /// request body, ``CardAutoBlock/held(cycleID:featureIssueID:reason:context:)`` and
    /// ``HeldWorkCards`` all read this one definition, rather than each deriving its own lanes and
    /// re-walking ``holder(of:currentCard:)``. `isConsidered` defaults to a Todo, not-removed Card — the
    /// shape every caller but ``HeldWorkCards`` wants. `cards` and `adoptedFrom` are one Cycle's Cards
    /// and its Feature's adoption origins, as ``RepoLane/derive(from:adoptedFrom:)`` takes them;
    /// `currentCard` re-reads a Card's live state, never trusting a lane's own stale snapshot.
    public static func heldCards(
        in cards: [CardRecord],
        where isConsidered: (CardRecord) -> Bool = { $0.state == .todo && !$0.isRemovedFromBoard },
        adoptedFrom: [Int64: String] = [:], currentCard: (CardRecord) throws -> CardRecord
    ) rethrows -> [(card: CardRecord, holder: CardRecord)] {
        var held: [(card: CardRecord, holder: CardRecord)] = []
        for lane in RepoLane.derive(from: cards, adoptedFrom: adoptedFrom) {
            for card in lane.cards where isConsidered(card) {
                if let holder = try lane.holder(of: card, currentCard: currentCard) {
                    held.append((card: card, holder: holder))
                }
            }
        }
        return held
    }
}
