import Domain
import Foundation
import Journal

/// Removal's attended delivery: shares the Outbox's safeguards, but must finish every entry now.
/// All local effects use the caller's isolated removal transaction and commit with removal itself.
public struct ProjectRemovalBoardDelivery: Sendable {
    public let maintenance: NightCardMaintenance

    public init(maintenance: NightCardMaintenance) { self.maintenance = maintenance }

    /// Lead draft, pending sponsor: salted by the Journal, with stable constituent write identities.
    public static func completionKey(issueID: String) -> String { "project-removed-night:\(issueID)" }

    /// Resolves eligibility from the Journal alone, keeping the board binding lazy. A killed Act may
    /// have committed its create receipt before recording the Night Card on the Night; an empty
    /// pending queue therefore does not establish that there is no card to complete.
    public static func requiresBoardDelivery(journal: JournalStore) throws -> Bool {
        if try !journal.pendingOutboxEntries().isEmpty { return true }
        guard let night = try journal.currentNight() else { return false }
        if night.nightCardIssueID != nil { return true }
        let clientID = OutboxClientID.make(
            projectID: journal.projectID, salt: journal.outboxSalt,
            key: NightCardMaintenance.createKey(nightStart: night.nightStart)
        )
        guard let entry = try journal.outboxEntry(clientID: clientID) else { return false }
        return (entry.state == .applied || entry.state == .aborted) && entry.result != nil
    }

    public func deliver() async throws {
        let journal = maintenance.journal
        let outbox = maintenance.outbox
        try journal.revalidateProjectRemoval(runID: outbox.runID)
        try await replay()
        try reconcileCreateReceipts()
        guard let night = try journal.currentNight(), let issueID = night.nightCardIssueID else { return }
        let issue = BoardObjectID(rawValue: issueID)
        guard let reading = outbox.reading else {
            throw ProjectRemovalDeliveryError.incomplete("the removal board has no live reading capability")
        }
        guard let object = try await reading.issue(issue) else {
            throw ProjectRemovalDeliveryError.incomplete("Night Card \(issueID) could not be read")
        }
        // Lead draft, pending sponsor: an archived card stays archived; removal never opens a replacement.
        guard object.archivedAt == nil else { return }
        let scope = try await NightCardScope.resolve(
            using: maintenance.provisioning, mapping: maintenance.mapping, footprint: maintenance.footprint
        )
        let renderings = try maintenance.completedRenderings(night: night, projectRemoved: true)
        let key = Self.completionKey(issueID: issueID)
        let entries = try outbox.accept([
            OutboxWrite(key: key + ":summary", write: .rewriteManagedBlockCompacting(
                issue: issue, renderings: renderings
            )),
            OutboxWrite(key: key + ":complete", write: .updateIssue(
                issue: issue, change: BoardIssueChange(workflowState: scope.completedState), undo: nil
            ))
        ])
        try await replay()
        // A nonempty failure list is not the only failure: fencing, budget and conditional skips must
        // not look like completion. Only the archive safeguard deliberately permits leaving it alone.
        for entry in entries {
            guard let recorded = try journal.outboxEntry(id: entry.id), recorded.state == .applied else {
                if try await reading.issue(issue)?.archivedAt != nil { return }
                throw ProjectRemovalDeliveryError.incomplete("Night Card \(issueID) completion was not applied")
            }
        }
        try journal.append(.nightCardCompleted(issueID: issueID), act: nil,
            runID: outbox.runID, nightID: night.id)
    }

    private func replay() async throws {
        let outbox = maintenance.outbox
        // A delivery can append a diagnostic; drain that too, bounded independently of flush firings.
        for _ in 0..<3 {
            if try outbox.journal.pendingOutboxEntries().isEmpty { return }
            let report = try await outbox.deliverPending()
            for delivery in report.deliveries {
                switch delivery.outcome {
                case .applied, .alreadyApplied, .superseded: break
                case .aborted(let reason):
                    guard reason.contains("is archived") || reason.contains("was removed from the board") else {
                        throw ProjectRemovalDeliveryError.incomplete(reason)
                    }
                case .failed(let reason): throw ProjectRemovalDeliveryError.incomplete(reason)
                case .deferred(let reason):
                    throw ProjectRemovalDeliveryError.incomplete("Outbox entry \(delivery.entry.id): \(reason)")
                }
            }
        }
        guard try outbox.journal.pendingOutboxEntries().isEmpty else {
            throw ProjectRemovalDeliveryError.incomplete("Outbox entries remain pending after bounded replay")
        }
    }

    private func reconcileCreateReceipts() throws {
        let journal = maintenance.journal
        let outbox = maintenance.outbox
        for mode in [NightMode.real, .rehearsal] {
            for night in try journal.nights(mode: mode) {
                var current = night.nightCardIssueID
                var visited: Set<String> = []
                while true {
                    let key = current.map {
                        NightCardMaintenance.replacementKey(nightStart: night.nightStart, predecessor: $0)
                    } ?? NightCardMaintenance.createKey(nightStart: night.nightStart)
                    guard visited.insert(key).inserted,
                          let entry = try journal.outboxEntry(clientID: outbox.clientID(for: key)),
                          entry.state == .applied || entry.state == .aborted, let result = entry.result
                    else { break }
                    try journal.reconcileRemovalNightCard(nightID: night.id, issueID: result, runID: outbox.runID)
                    current = result
                }
            }
        }
    }
}

public enum ProjectRemovalDeliveryError: Error, CustomStringConvertible {
    case incomplete(String)

    public var description: String {
        switch self {
        case .incomplete(let reason): "Project removal board delivery did not complete: \(reason); retry removal"
        }
    }
}
