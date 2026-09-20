import Domain
import Foundation

/// The model-authored Cards for a selected Feature (roadmap P9.4; spec: feature-authoring/
/// author-the-cycle-and-card-dag): reads the specification against the repositories as they stand at
/// authoring time and returns the Feature's definition of done and its Cards. It judges;
/// ``AuthoringTransaction`` validates what it returns and writes it as one transaction.
/// ``RoutedFeatureBreakdown`` is the agent CLI implementation; it throws ``AuthoringDispatchFault`` when
/// no Route answered, which ``AuthoringTransaction`` records as an authoring fault.
public protocol FeatureBreakdownDrafting: Sendable {
    func breakdown(
        for selection: SelectedFeature, mainlines: ResolvedMainlines, context: ActContext
    ) async throws -> FeatureBreakdown
}

/// Why a breakdown was refused before anything was accepted into the Outbox.
public enum FeatureBreakdownError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A Card names a repository the selection did not resolve to.
    case repositoryOutsideSelection(title: String, repository: String)
    /// A Card has an empty title.
    case emptyTitle(position: Int)
    /// A Card has an empty or whitespace-only Architectural Brief (roadmap P9.6; spec: feature-
    /// authoring/author-an-architectural-brief): every authored Card carries a brief before dispatch.
    case emptyBrief(position: Int)
    /// A Card carries the Kind reserved for the author Act, which is never read off a Card.
    case reservedKind(title: String, kind: String)
    /// The transaction would author no Card at all — neither a new one nor an adopted one.
    case noCards

    public var description: String {
        switch self {
        case .repositoryOutsideSelection(let title, let repository):
            "Card '\(title)' names repository '\(repository)', which the selection did not resolve to."
        case .emptyTitle(let position):
            "Card \(position) of the breakdown has an empty title."
        case .emptyBrief(let position):
            "Card \(position) of the breakdown has an empty Architectural Brief."
        case .reservedKind(let title, let kind):
            "Card '\(title)' carries Kind '\(kind)', which is reserved for the author Act."
        case .noCards:
            "The breakdown authors no Card and the selection adopts none."
        }
    }
}

/// What the engine can check about a breakdown. It cannot judge the authoring invariant — that every
/// Card stands alone against the repositories as they are — because that is model judgement: work that
/// crosses repositories is split into a sequence of Features at selection, and work that is sequential
/// inside one repository is authored as one coarser Card. The engine does not fake a check for it; a
/// ``CardDraft`` simply has no way to link to another Card.
enum FeatureBreakdownValidation {
    static func validate(_ breakdown: FeatureBreakdown, for selection: SelectedFeature) throws {
        let repositories = Set(selection.repositories)
        for (index, card) in breakdown.cards.enumerated() {
            guard !card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FeatureBreakdownError.emptyTitle(position: index + 1)
            }
            guard !card.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FeatureBreakdownError.emptyBrief(position: index + 1)
            }
            guard !card.kind.isReservedForAuthoring else {
                throw FeatureBreakdownError.reservedKind(title: card.title, kind: card.kind.description)
            }
            guard repositories.contains(card.repository) else {
                throw FeatureBreakdownError.repositoryOutsideSelection(
                    title: card.title, repository: card.repository
                )
            }
        }
        guard !breakdown.cards.isEmpty || !selection.adoptedCardIssueIDs.isEmpty else {
            throw FeatureBreakdownError.noCards
        }
    }
}
