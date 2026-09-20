import Domain
import Foundation
import Repositories

// Resolves every Definition of Done clause a breakdown drafted, before anything is accepted into the
// Outbox (roadmap P9.5; spec: feature-authoring/author-citable-definitions-of-done, first and second
// stories): a clause with empty text, an empty citation, or a citation that does not resolve is
// uncitable, and is dropped rather than written speculatively.

/// What resolving a ``FeatureBreakdown``'s drafted clauses found: which clauses may be written, and
/// which were dropped.
struct AuthoringCitationResolution {
    /// The Feature-level clauses that resolved, citable in draft order.
    let featureClauses: [DefinitionOfDoneClauseDraft]
    /// Per-Card citable clauses, aligned by index with the breakdown's `cards`.
    let cardClauses: [[DefinitionOfDoneClauseDraft]]
    /// Every clause dropped because it could not be cited, in the order encountered: the Feature level
    /// first, then each Card in draft order.
    let uncitable: [UncitableClause]

    /// True when the Feature level, or any newly authored Card, is left with zero citable clauses — the
    /// thin-spec Refusal (roadmap P9.5, second story).
    var isThin: Bool {
        featureClauses.isEmpty || cardClauses.contains { $0.isEmpty }
    }
}

/// Where a batch of drafted clauses sits: the Feature level, or one named Card — bundled so
/// ``AuthoringCitations/resolveLevel(_:at:resolver:context:uncitable:)`` stays under the parameter-count
/// limit.
private struct ClauseLevel {
    let level: String
    let cardTitle: String?

    static let feature = ClauseLevel(level: "feature", cardTitle: nil)
    static func card(_ title: String) -> ClauseLevel { ClauseLevel(level: "card", cardTitle: title) }
}

enum AuthoringCitations {
    private static let emptyTextReason = "the clause has no text"
    private static let emptyCitationReason = "the clause has no citation"
    private static let noRepositoriesReason =
        "this Project has no repositories configured to resolve citations against"

    /// Resolves every clause the breakdown drafted, Feature level first and then each Card in draft
    /// order, against `context.repositories` (never speculatively: a nil `context.repositories` makes
    /// every citation unresolved).
    static func resolve(
        _ breakdown: FeatureBreakdown, using resolver: any CitationResolving, context: ActContext
    ) async -> AuthoringCitationResolution {
        var uncitable: [UncitableClause] = []
        let featureClauses = await resolveLevel(
            breakdown.definitionOfDone, at: .feature, resolver: resolver, context: context, uncitable: &uncitable
        )
        var cardClauses: [[DefinitionOfDoneClauseDraft]] = []
        for card in breakdown.cards {
            let clauses = await resolveLevel(
                card.definitionOfDone, at: .card(card.title), resolver: resolver, context: context,
                uncitable: &uncitable
            )
            cardClauses.append(clauses)
        }
        return AuthoringCitationResolution(
            featureClauses: featureClauses, cardClauses: cardClauses, uncitable: uncitable
        )
    }

    private static func resolveLevel(
        _ drafts: [DefinitionOfDoneClauseDraft], at level: ClauseLevel,
        resolver: any CitationResolving, context: ActContext, uncitable: inout [UncitableClause]
    ) async -> [DefinitionOfDoneClauseDraft] {
        var citable: [DefinitionOfDoneClauseDraft] = []
        for draft in drafts {
            if let reason = await uncitableReason(draft, resolver: resolver, context: context) {
                uncitable.append(UncitableClause(
                    level: level.level, cardTitle: level.cardTitle, text: draft.text,
                    citation: draft.citation.rawValue, reason: reason
                ))
            } else {
                citable.append(draft)
            }
        }
        return citable
    }

    /// Nil when the clause is citable; the resolver's (or the engine's own structural) reason otherwise.
    private static func uncitableReason(
        _ draft: DefinitionOfDoneClauseDraft, resolver: any CitationResolving, context: ActContext
    ) async -> String? {
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return emptyTextReason
        }
        guard !draft.citation.rawValue.isEmpty else {
            return emptyCitationReason
        }
        guard let repositories = context.repositories else {
            return noRepositoriesReason
        }
        let resolution = await resolver.resolve(draft.citation, in: repositories, mainlines: context.mainlines)
        return resolution.resolves ? nil : (resolution.failureReason ?? "the citation could not be resolved")
    }
}
