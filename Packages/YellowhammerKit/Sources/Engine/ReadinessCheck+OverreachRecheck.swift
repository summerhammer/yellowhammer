import Domain
import Foundation
import Journal
import Repositories

extension ReadinessCheck {
    /// Re-checks every Work Card of the in-flight Cycle currently in Waiting on You under `overreach`
    /// (bounds/refuse-protected-paths-before-dispatch; roadmap P8.3, OQ89 rule 3, OQ90).
    ///
    /// Runs once per build Act when ``BuildAct/readiness`` is non-nil, before lanes are derived. A Card whose
    /// Declared Scope or repository Protected Paths configuration has cleared leaves Waiting on You and returns to
    /// Todo; a Card that still overlaps has its reason updated if the overlaps changed, or is left untouched if
    /// unchanged. A Card whose read Transcription Block has diverged transitions to Waiting on You under
    /// `divergence`.
    public func recheckOverreach(context: BuildActContext) async throws {
        let journal = context.act.journal
        let cards = try journal.cards(cycleID: context.cycleID)
        let candidates = cards.filter {
            $0.state == .waitingOnYou && $0.waitingReason == .overreach && !$0.isRemovedFromBoard
        }

        for candidate in candidates {
            switch try journal.claimCardLease(cardID: candidate.id, runID: context.act.runID) {
            case .held:
                continue
            case .claimed, .reclaimed:
                break
            }

            do {
                let current = try journal.card(id: candidate.id)
                guard current.state == .waitingOnYou, current.waitingReason == .overreach,
                      !current.isRemovedFromBoard else {
                    _ = try journal.releaseCardLease(cardID: candidate.id, runID: context.act.runID)
                    continue
                }
                try await recheck(card: current, context: context)
            } catch {
                _ = try? journal.releaseCardLease(cardID: candidate.id, runID: context.act.runID)
                throw error
            }
            _ = try journal.releaseCardLease(cardID: candidate.id, runID: context.act.runID)
        }
    }

    private func recheck(card: CardRecord, context: BuildActContext) async throws {
        let journal = context.act.journal
        let matches = try protectedPathMatches(card: card, context: context)

        if matches.isEmpty {
            try await transitionToReady(card: card, context: context)
            return
        }

        if let repositories = context.act.repositories {
            let blocks = try journal.transcriptionBlocks(cardID: card.id).filter(\.isRead)
            let report = await provenance.evaluate(
                blocks.map(\.block), projectRepositories: repositories, mainlines: context.recordedBaseMainlines
            )
            if report.hasDivergence {
                try recordOverlaps(matches, card: card, context: context)
                _ = try await recordDivergence(report: report, card: card, context: context)
                return
            }
        }

        let lastRecorded = try Self.lastRecordedOverlaps(cardID: card.id, journal: journal)
        if Set(matches) != Set(lastRecorded) {
            try recordOverlaps(matches, card: card, context: context)
            if let outbox = context.act.outbox {
                let sortedLines = matches.map {
                    "- `\($0.declaredPath)` overlaps `\($0.protectedPath)` in repository `\($0.repository)`."
                }.sorted()
                let sha = ManagedBlockFence.sha256(sortedLines.joined(separator: "\n"))
                let key = "protected-path:\(card.issueID):\(card.stateVersion):\(sha)"
                let body = refusalCommentBody(overlaps: matches)
                let write = BoardWrite.createComment(issue: BoardObjectID(rawValue: card.issueID), body: body)
                _ = try await outbox.post(OutboxWrite(key: key, write: write, cardID: card.id))
            }
        }
    }

    private func transitionToReady(card: CardRecord, context: BuildActContext) async throws {
        if let board = context.act.board, let outbox = context.act.outbox {
            let scope = try await BoardStateScope.resolve(using: board)
            let projection = BoardStateProjection(journal: context.act.journal, outbox: outbox, scope: scope)
            _ = try await projection.transition(card: card, to: .ready)
        } else {
            _ = try context.act.journal.transitionCard(
                cardID: card.id, to: .todo, runID: context.act.runID, act: context.act.act,
                nightID: context.act.night.id
            )
        }
    }

    /// Computes a Card's latest recorded protected-path overlaps from the Journal, by runID, nightID
    /// and occurredAt.
    public static func lastRecordedOverlaps(
        cardID: Int64, journal: JournalStore
    ) throws -> [ProtectedPathRefusal] {
        let events = try journal.events(ofType: .protectedPathRefused).filter {
            if case .protectedPathRefused(let id, _, _, _, _) = $0.event { return id == cardID }
            return false
        }
        guard let latest = events.last else { return [] }
        return events.filter {
            $0.runID == latest.runID && $0.nightID == latest.nightID && $0.occurredAt == latest.occurredAt
        }.compactMap {
            if case .protectedPathRefused(_, _, let repository, let declared, let protectedPath) = $0.event {
                return ProtectedPathRefusal(
                    repository: repository, declaredPath: declared, protectedPath: protectedPath
                )
            }
            return nil
        }
    }
}
