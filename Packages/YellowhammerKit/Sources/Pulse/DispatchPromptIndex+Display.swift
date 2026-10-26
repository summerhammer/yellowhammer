import Foundation
import Journal

extension DispatchPromptIndex {
    /// Resolves each item's Feature and Work Card display text from `journal`, the way ``NightAccount`` names
    /// them: a Card by its display identifier (else its issue key), a Feature by its display identifier. An
    /// id the Journal does not know stays nil: the raw ids are Linear UUIDs, so they are never shown instead.
    /// Each Card and Feature is read once.
    static func resolvingDisplays(
        of items: [DispatchPromptItem], in journal: JournalStore
    ) throws -> [DispatchPromptItem] {
        var cards: [Int64: String?] = [:]
        var features: [String: String?] = [:]
        func cardDisplay(_ cardID: Int64) throws -> String? {
            if let cached = cards[cardID] { return cached }
            let display: String?
            do {
                display = try journal.card(id: cardID).issueIDForDisplay
            } catch JournalError.cardUnknown {
                display = nil
            }
            cards[cardID] = .some(display)
            return display
        }
        func featureDisplay(_ issueID: String) throws -> String? {
            if let cached = features[issueID] { return cached }
            let feature = try journal.feature(issueID: issueID)
            let display = feature?.issueIDForDisplay ?? feature?.issueKey
            features[issueID] = .some(display)
            return display
        }
        return try items.map { item in
            var resolved = item
            resolved.workCardDisplay = try item.cardID.flatMap(cardDisplay)
            resolved.featureDisplay = try item.featureIssueID.flatMap(featureDisplay)
            return resolved
        }
    }
}
