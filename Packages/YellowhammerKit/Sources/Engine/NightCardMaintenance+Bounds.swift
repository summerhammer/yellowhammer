import Domain
import Foundation
import Journal

// The Night Summary's `**Bounds:**` and `**Standing items:**` sections (roadmap P11.6; bounds
// overview), split out of NightCardMaintenance.swift to keep that file under the file length limit.

extension NightCardMaintenance {
    /// The three Project-scoped Bounds the Night Summary reports proximity to (roadmap P11.6; bounds
    /// overview): plain Ints, the same stance as `AuthorAct`'s `unansweredNightsMax` — the Engine never
    /// imports `Config`, so `EngineCommand` is the one place these are read from `project.bounds`.
    public struct Bounds: Equatable, Sendable {
        public let reselectionsMax: Int
        public let consecutiveRefusalsMax: Int
        public let failedAdoptionsMax: Int

        public init(reselectionsMax: Int = 2, consecutiveRefusalsMax: Int = 3, failedAdoptionsMax: Int = 2) {
            self.reselectionsMax = reselectionsMax
            self.consecutiveRefusalsMax = consecutiveRefusalsMax
            self.failedAdoptionsMax = failedAdoptionsMax
        }
    }

    /// The `**Bounds:**` section's three lines: this Night's proximity to `reselections_max`,
    /// `consecutive_refusals_max` and `failed_adoptions_max`, always present on a completed block
    /// regardless of whether anything happened this Night.
    func boundsLines(night: NightRecord) throws -> [String] {
        var reselections = 0
        var refusalCounts: [String: Int] = [:]
        var refusalOrder: [String] = []
        var adoptionRefusedCardIDs: [Int64] = []
        for record in try journal.events() where record.nightID == night.id {
            switch record.event {
            case .featureReselected:
                reselections += 1
            case .refusalOpened(let feature, let count, _, _), .refusalRepeated(let feature, let count, _, _):
                if refusalCounts[feature] == nil { refusalOrder.append(feature) }
                refusalCounts[feature] = max(refusalCounts[feature] ?? 0, count)
            case .adoptionRefused(let cardID, _, _, _, _):
                if !adoptionRefusedCardIDs.contains(cardID) { adoptionRefusedCardIDs.append(cardID) }
            default:
                break
            }
        }

        return [
            reselectionsLine(reselections),
            refusalsLine(refusalOrder, counts: refusalCounts),
            try adoptionsLine(adoptionRefusedCardIDs)
        ]
    }

    private func reselectionsLine(_ reselections: Int) -> String {
        "`reselections_max` \(bounds.reselectionsMax): \(reselections) " +
            "re-selection\(reselections == 1 ? "" : "s") used this Night."
    }

    private func refusalsLine(_ order: [String], counts: [String: Int]) -> String {
        guard !order.isEmpty else {
            return "`consecutive_refusals_max` \(bounds.consecutiveRefusalsMax): no Refusal this Night."
        }
        let named = order.map { feature in
            "Feature `\(feature)`: \(counts[feature] ?? 0) of \(bounds.consecutiveRefusalsMax) " +
                "consecutive Refusals"
        }.joined(separator: "; ")
        return "`consecutive_refusals_max` \(bounds.consecutiveRefusalsMax): \(named)."
    }

    private func adoptionsLine(_ cardIDs: [Int64]) throws -> String {
        guard !cardIDs.isEmpty else {
            return "`failed_adoptions_max` \(bounds.failedAdoptionsMax): no failed Adoption this Night."
        }
        let named = try cardIDs.map { cardID -> String in
            let card = try journal.card(id: cardID)
            return "Card `\(card.issueID)`: \(card.failedAdoptions) of \(bounds.failedAdoptionsMax) " +
                "consecutive failed Adoptions"
        }.joined(separator: "; ")
        return "`failed_adoptions_max` \(bounds.failedAdoptionsMax): \(named)."
    }

    /// The `**Standing items:**` section's lines: every currently promoted Refusal and Card, rendered
    /// on every completed Night Card while any exist — not only the Night of promotion.
    func standingItemLines() throws -> [String] {
        let refusalLines = try journal.standingRefusals().map { record in
            "Feature `\(record.featureName)` has been refused \(record.consecutiveRefusals) times in a row, " +
                "past `consecutive_refusals_max` \(bounds.consecutiveRefusalsMax) — a standing decision."
        }
        let cardLines = try journal.standingDivergenceCards().map { card in
            "Card `\(card.issueID)` has failed Adoption \(card.failedAdoptions) times in a row, past " +
                "`failed_adoptions_max` \(bounds.failedAdoptionsMax) — a standing decision."
        }
        return refusalLines + cardLines
    }

    /// The re-selection walk's and the two standing-item promotions' own Night Summary lines (P11.6),
    /// split out of `authoringLine(for:)` to keep that function under the length limit.
    static func boundsAuthoringLine(for event: JournalEvent) -> String? {
        switch event {
        case .featureReselected(let depth, let afterRefusalOf, let reselectionsMax):
            return """
                Re-selected after Feature `\(afterRefusalOf)` was refused: re-selection \(depth) of \
                \(reselectionsMax).
                """
        case .reselectionBoundReached(let depth, let reselectionsMax):
            return """
                `reselections_max` (\(reselectionsMax)) reached at depth \(depth): this Night authors no \
                further Feature.
                """
        case .refusalPromotedToStandingItem(let feature, let consecutiveRefusals, let consecutiveRefusalsMax):
            return """
                Feature `\(feature)` was promoted to a standing item: refused \(consecutiveRefusals) times \
                in a row, past `consecutive_refusals_max` \(consecutiveRefusalsMax).
                """
        case .cardPromotedToStandingItem(_, let issueID, let failedAdoptions, let failedAdoptionsMax):
            return """
                Card `\(issueID)` was promoted to a standing item: failed Adoption \(failedAdoptions) times \
                in a row, past `failed_adoptions_max` \(failedAdoptionsMax).
                """
        default:
            return nil
        }
    }
}
