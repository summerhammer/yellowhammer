import Domain
import Foundation
import GRDB

// The read behind the selection pass's `## Board state` section (issue #556; spec:
// feature-authoring/select-the-next-feature): what this Project's own Journal already knows of its board,
// so the model has no reason to go looking for state itself. Journal only — no board read.

extension JournalStore {
    /// How many Features the selection pass is told about, most recent first.
    public static let selectionBoardStateFeatureCap = 20

    /// The Features authored for this Project (newest first, capped), the Cards in Waiting on You across
    /// the Journal, and every Feature in the Unmerged Feature Stack U (roadmap P23.2), oldest first. Never
    /// carries an issue id: only the human identifiers a board shows.
    ///
    /// The `feature` table has no name column; a Feature's name is read from the `FeatureAuthored` event
    /// that finalised it, joined on the Feature Issue's id. A Feature with no such event (the log predates
    /// it) is listed without a name.
    public func selectionBoardState() throws -> SelectionBoardState {
        let stack = try unmergedFeatureStack()
        return try read { db in
            var namesByIssueID: [String: String] = [:]
            for record in try Self.events(db, ofType: .featureAuthored) {
                if case .featureAuthored(let payload) = record.event {
                    namesByIssueID[payload.featureIssueID] = payload.name
                }
            }
            let featureRows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM feature ORDER BY created_at DESC, id DESC LIMIT ?",
                arguments: [Self.selectionBoardStateFeatureCap]
            )
            let features = try featureRows.map { row -> SelectionBoardState.AuthoredFeature in
                let feature = try Self.featureRecord(from: row)
                return SelectionBoardState.AuthoredFeature(
                    name: namesByIssueID[feature.issueID],
                    identifier: Self.featureIdentifier(feature),
                    outcome: Self.featureOutcome(feature)
                )
            }
            let cardRows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM card
                WHERE state = ? AND removed_from_board IS NULL
                ORDER BY repository ASC, authored_order ASC
                """,
                arguments: [CardState.waitingOnYou.rawValue]
            )
            let waiting = try cardRows.map { row -> SelectionBoardState.WaitingCard in
                let card = try Self.cardRecord(from: row)
                let identifier = Self.cardIdentifier(card)
                return SelectionBoardState.WaitingCard(
                    identifier: identifier,
                    title: card.title.flatMap { $0.isEmpty ? nil : $0 } ?? identifier,
                    repository: card.repository,
                    reason: card.waitingReason?.rawValue ?? "no reason recorded"
                )
            }
            return SelectionBoardState(features: features, waitingCards: waiting, unmergedFeatures: stack.map {
                Self.unmergedFeature($0, name: namesByIssueID[$0.feature.issueID])
            })
        }
    }

    private static func unmergedFeature(
        _ member: UnmergedFeature, name: String?
    ) -> SelectionBoardState.UnmergedFeature {
        SelectionBoardState.UnmergedFeature(
            name: name,
            identifier: featureIdentifier(member.feature),
            touchedRepositories: member.touchedRepositories,
            unmergedBranches: member.unmergedRepositories.map { repository in
                SelectionBoardState.UnmergedBranch(
                    repository: repository,
                    branch: member.branches[repository]?.name
                        ?? member.feature.worktreeName?.rawValue ?? "no branch recorded"
                )
            }
        )
    }

    private static func featureIdentifier(_ feature: FeatureRecord) -> String {
        for candidate in [feature.issueKey, feature.issueIDForDisplay] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return "no board identifier yet"
    }

    private static func featureOutcome(_ feature: FeatureRecord) -> String {
        // Board completion verifies and merges nothing, so it is never reported as landed (P22.2).
        if feature.closedBy == .completion { return "completed on the Board" }
        if feature.closedBy != nil { return "landed" }
        if feature.abandonedAt != nil { return "abandoned" }
        return feature.state
    }

    private static func cardIdentifier(_ card: CardRecord) -> String {
        for candidate in [card.issueIDForDisplay, card.issueKey] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        if let title = card.title, !title.isEmpty { return title }
        return "unidentified Card"
    }
}
