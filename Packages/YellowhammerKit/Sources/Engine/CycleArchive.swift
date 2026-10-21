import Domain
import Foundation
import Journal

/// Why a Cycle could not be archived: the land Act records it and the Cycle stays unarchived so the next
/// firing retries.
public struct CycleArchiveFault: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// Archives the Cycle on a verified Feature (roadmap P10.7; spec: verification/archive-the-cycle-on-a-
/// verified-feature), the real ``CycleArchiving``. Called only when Verification's verdict is all-met,
/// after every lane's pull request has opened.
///
/// The Feature is no longer in flight once archived, and archival releases the in-flight slot (spec:
/// verification/archive-the-cycle-on-a-verified-feature): the Feature enters the Unmerged Feature Stack U until
/// an Observed Merge in every repository it pushed to, and the author Act may author its successor on its landed
/// tips while |U| stays below `unmerged_features_max` (roadmap P23.5). At the bound the author Act authors
/// nothing — a quiet Night. Surviving Blocked Cards are detached from the Feature Issue (`parentId` cleared) with
/// their counters, round history and Block Reason intact — nothing else touches those Journal rows here, so a
/// later adoption reads them unchanged. Archival never merges or closes a pull request. Once the Cycle is
/// archived, a landed pin its recorded bases kept past their Observed Merge is deleted
/// (``LandedPinRelease/releaseBasePins(of:repositories:journal:)``).
public struct CycleArchive: CycleArchiving, Sendable {
    public init() { }

    public func archive(_ context: LandActFeatureContext) async throws {
        let journal = context.act.journal
        guard let recorded = try journal.featureVerification(cycleID: context.cycleID) else {
            throw CycleArchiveFault(reason: "the Cycle has no recorded Verification to archive with")
        }
        guard Self.allClausesMet(recorded) else {
            throw CycleArchiveFault(reason: "the recorded Verification has clauses that are not met")
        }

        let detachedCards = try await postBoardWrites(context: context)

        let firstArchive = try journal.archiveCycle(
            cycleID: context.cycleID, featureID: context.feature.id, closedBy: .verification,
            runID: context.act.runID
        )
        if firstArchive {
            try journal.append(
                .cycleArchived(
                    cycleID: context.cycleID, featureIssueID: context.feature.issueID, closedBy: .verification,
                    detachedCards: detachedCards
                ),
                act: context.act.act, runID: context.act.runID, nightID: context.act.night.id
            )
            let act = context.act
            await LandedPinRelease(act: act.act, runID: act.runID, nightID: act.night.id).releaseBasePins(
                of: context.feature, repositories: act.repositories?.workingRepos ?? [], journal: journal
            )
        }
    }

    /// The land Act's all-met rule (mirrors ``FeatureVerification/verdict(of:)``), checked again here in
    /// defence in depth: a Cycle is archived only when every Definition of Done clause is met.
    static func allClausesMet(_ record: FeatureVerificationRecord) -> Bool {
        !record.clauses.isEmpty && record.clauses.allSatisfy { $0.verdict == .met }
    }

    /// Detaches every Blocked Card from the Feature Issue and moves the Feature Issue to Done, keyed so
    /// a retried land Act re-queues the same writes rather than duplicating them. Returns how many Cards
    /// were detached. Skipped when no Outbox or board is wired.
    private func postBoardWrites(context: LandActFeatureContext) async throws -> Int {
        guard let outbox = context.act.outbox, let board = context.act.board else { return 0 }
        let cards = try context.act.journal.cards(cycleID: context.cycleID)
        // A removed Card (OQ142) is set aside: Yellowhammer writes nothing to its issue, so it stays attached.
        let blocked = cards.filter { $0.state == .blocked && !$0.isRemovedFromBoard }

        for card in blocked {
            let key = "land:\(context.cycleID):detach:\(card.issueID)"
            let issue = BoardObjectID(rawValue: card.issueID)
            let change = BoardIssueChange(parent: .clear)
            let write = OutboxWrite(key: key, write: .updateIssue(issue: issue, change: change, undo: nil))
            _ = try await outbox.post(write)
        }

        let scope = try await BoardStateScope.resolve(using: board)
        let projection = BoardStateProjection(journal: context.act.journal, outbox: outbox, scope: scope)
        let featureIssue = BoardObjectID(rawValue: context.feature.issueID)
        _ = try await projection.transition(featureIssue: featureIssue, to: .done)

        return blocked.count
    }
}
