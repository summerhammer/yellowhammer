import Domain
import Foundation
import Journal
import Repositories

/// A read-only version of the dispatch judgement for an opening snapshot. It intentionally makes
/// no Card state transitions, claims no Card lease, and records no readiness or reconciliation events.
public enum OpeningCardReadiness: Equatable, Sendable {
    case ready
    case notReady
    case unknown
}

extension ReadinessCheck {
    public func inspectAtOpening(
        card: CardRecord, object: BoardObject, journal: JournalStore,
        repositories: ProjectRepositories?, mainlines: ResolvedMainlines
    ) async throws -> OpeningCardReadiness {
        let boardStatus = openingBoardStatus(card: card, object: object)
        guard boardStatus == .ready else { return boardStatus }
        let boardBlock: ParsedCardBlock?
        if let description = object.description {
            guard case .success(let parts) = ManagedBlockFence.parts(of: description) else { return .unknown }
            boardBlock = CardManagedBlockParser.parse(block: parts.block)
        } else {
            boardBlock = nil
        }

        let scope = try boardBlock?.scope ?? journal.declaredScope(cardID: card.id)
        let protectedPaths = repositories?.workingRepo(named: card.repository)?.protectedPaths ?? []
        if ProtectedPaths.match(declaredScope: scope, protectedPaths: protectedPaths) != nil { return .notReady }

        let prose = try boardBlock?.briefProse ?? journal.architecturalBriefProse(cardID: card.id)
        let records = try journal.transcriptionBlocks(cardID: card.id)
        if referencesAwaitDispatch(records, boardBlock: boardBlock) { return .unknown }
        let blocks = records.map(\.block)
        let clauses = try openingClauses(card: card, boardBlock: boardBlock, journal: journal)
        if (prose ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && blocks.isEmpty {
            return .notReady
        }
        guard !clauses.isEmpty, let repositories else { return .notReady }

        let citationStatus = await checkCitations(clauses, repositories: repositories, mainlines: mainlines)
        if citationStatus == .notReady { return .notReady }
        let provenanceStatus = await checkProvenance(blocks, repositories: repositories, mainlines: mainlines)
        if provenanceStatus == .notReady { return .notReady }
        return citationStatus == .unknown || provenanceStatus == .unknown ? .unknown : .ready
    }

    /// An edited, added or removed reference, or one still unread, is read at dispatch: this snapshot reads
    /// nothing and writes nothing, so it cannot say.
    private func referencesAwaitDispatch(_ records: [TranscriptionBlockRecord], boardBlock: ParsedCardBlock?) -> Bool {
        if records.contains(where: { !$0.isRead }) { return true }
        guard let boardBlock else { return false }
        let matching = TranscriptionReferenceMatch.match(board: boardBlock.transcriptions, records: records)
        let anyEdited = matching.blocks.contains { if case .edited = $0 { return true } else { return false } }
        return anyEdited || !matching.deletions.isEmpty
    }

    private func openingBoardStatus(card: CardRecord, object: BoardObject) -> OpeningCardReadiness {
        guard card.state == .todo else { return .notReady }
        guard !object.isTrashed, object.archivedAt == nil else { return .unknown }
        if object.workflowState.isShelved { return .notReady }
        return object.workflowState.name == CardState.todo.rawValue ? .ready : .unknown
    }

    private func checkCitations(
        _ clauses: [OpeningClause], repositories: ProjectRepositories, mainlines: ResolvedMainlines
    ) async -> OpeningCardReadiness {
        var unknown = false
        for clause in clauses {
            let citation = SpecCitation(clause.citation)
            let resolution = await citations.resolve(citation, in: repositories, mainlines: mainlines)
            if !resolution.resolves {
                if isReadFailure(resolution.failureReason) {
                    unknown = true
                } else {
                    return .notReady
                }
            }
        }
        return unknown ? .unknown : .ready
    }

    private func checkProvenance(
        _ blocks: [TranscriptionBlock], repositories: ProjectRepositories, mainlines: ResolvedMainlines
    ) async -> OpeningCardReadiness {
        var unknown = false
        let provenanceReport = await provenance.evaluate(
            blocks, projectRepositories: repositories, mainlines: mainlines
        )
        for result in provenanceReport.results {
            switch result.verdict {
            case .stale: return .notReady
            case .untestable: unknown = true
            case .clean: break
            }
        }
        return unknown ? .unknown : .ready
    }

    private struct OpeningClause {
        let citation: String
    }

    private func openingClauses(
        card: CardRecord, boardBlock: ParsedCardBlock?, journal: JournalStore
    ) throws -> [OpeningClause] {
        if let boardBlock {
            return boardBlock.clauses.map { OpeningClause(citation: $0.citation ?? "") }
        }
        return try journal.clauses(issueID: card.issueID).map { OpeningClause(citation: $0.locationID) }
    }

    private func isReadFailure(_ reason: String?) -> Bool {
        guard let reason else { return true }
        return reason.hasPrefix("Could not resolve mainline commit:") ||
            reason.hasPrefix("Specification source repository does not exist")
    }
}
