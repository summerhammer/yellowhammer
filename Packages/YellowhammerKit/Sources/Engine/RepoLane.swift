import Domain
import Journal

/// The Cards of one Feature belonging to one Repo, in authored order (glossary → Repo Lane). Derived
/// from the Cards' repository labels on every build Act, never stored.
public struct RepoLane: Equatable, Sendable {
    public let repository: String
    /// Every Card of the lane, in authored order, all states.
    public let cards: [CardRecord]

    public init(repository: String, cards: [CardRecord]) {
        self.repository = repository
        self.cards = cards
    }

    /// The Cards this lane still has to run: Todo only, and never a removed one (trashed, or archived
    /// while in play; OQ142) — it is set aside, not work.
    public var runnable: [CardRecord] {
        cards.filter { $0.state == .todo && !$0.isRemovedFromBoard }
    }

    /// Groups `cards` into Repo Lanes: one lane per repository, ordered by repository name, each
    /// lane's Cards in the order they were authored.
    public static func derive(from cards: [CardRecord]) -> [RepoLane] {
        var byRepository: [String: [CardRecord]] = [:]
        for card in cards {
            byRepository[card.repository, default: []].append(card)
        }
        return byRepository.keys.sorted().map { repository in
            let cards = byRepository[repository]!.sorted { $0.authoredOrder < $1.authoredOrder }
            return RepoLane(repository: repository, cards: cards)
        }
    }
}
