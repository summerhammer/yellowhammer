import Domain
import Foundation
import Journal

/// Creates and completes one Project's Night Card, through the Outbox like every other board write —
/// so a crashed and resumed Act cannot create two (spec: open-and-close-the-night-card).
public struct NightCardMaintenance: Sendable {
    public let journal: JournalStore
    public let outbox: Outbox
    /// Resolved into a ``NightCardScope`` only when a board write actually needs it — never cached,
    /// so a build Act of a Night whose card already exists reads nothing from the board.
    public let provisioning: any BoardProvisioning

    public init(journal: JournalStore, outbox: Outbox, provisioning: any BoardProvisioning) {
        self.journal = journal
        self.outbox = outbox
        self.provisioning = provisioning
    }

    public static func createKey(nightStart: NightStart) -> String {
        "night-card:\(nightStart):create"
    }

    public static func summaryKey(nightStart: NightStart, hash: String) -> String {
        "night-card:\(nightStart):summary:\(hash)"
    }

    public static func completeKey(nightStart: NightStart) -> String {
        "night-card:\(nightStart):complete"
    }

    public static func authoringKey(nightStart: NightStart, hash: String) -> String {
        "night-card:\(nightStart):authoring:\(hash)"
    }

    public enum Opening: Equatable, Sendable {
        /// The Night already carried a Night Card issue id; nothing was written.
        case alreadyRecorded(issueID: String)
        /// A Night Card was recorded. `replayed` is true when the board had already applied the
        /// create — a resumed Act finding what a killed one already did.
        case opened(issueID: String, replayed: Bool)
    }

    /// Creates the Project's Night Card, unless one is already recorded for this Night. Called before
    /// any work, by the first Act of the Night (DR7): an idle Night still gets a card.
    public func open(night: NightRecord) async throws -> Opening {
        if let existing = night.nightCardIssueID {
            return .alreadyRecorded(issueID: existing)
        }
        guard let act = outbox.act else {
            throw NightCardError.notOpened(reason: "the Outbox has no Act to stamp the Night Card with")
        }
        let scope = try await NightCardScope.resolve(using: provisioning)
        let key = Self.createKey(nightStart: night.nightStart)
        let draft = BoardIssueDraft(
            team: scope.team,
            title: "Night \(night.nightStart)",
            description: ManagedBlockFence.initialDescription(
                rendered: NightCardBlock.opened(night: night, projectID: journal.projectID)
            ),
            labels: [scope.nightCardLabel]
        )
        let delivery = try await outbox.post(OutboxWrite(key: key, write: .createIssue(draft, parentKey: nil)))
        switch delivery.outcome {
        case .applied(let id):
            guard let id else {
                throw NightCardError.notOpened(reason: "the board applied the create but returned no id")
            }
            try journal.recordNightCard(id: night.id, issueID: id.rawValue, act: act, runID: outbox.runID)
            return .opened(issueID: id.rawValue, replayed: false)
        case .alreadyApplied(let id):
            try journal.recordNightCard(id: night.id, issueID: id.rawValue, act: act, runID: outbox.runID)
            return .opened(issueID: id.rawValue, replayed: true)
        case .deferred(.behindAnotherEntry):
            // The create may have already been applied by an earlier, crashed run: `deliverPending`
            // only iterates pending entries, so an entry the earlier run left `.applied` never appears
            // in this delivery's report, and `post` reports it as merely deferred. Read it directly.
            if let entry = try journal.outboxEntry(clientID: outbox.clientID(for: key)),
               entry.state == .applied, let result = entry.result {
                try journal.recordNightCard(id: night.id, issueID: result, act: act, runID: outbox.runID)
                return .opened(issueID: result, replayed: true)
            }
            throw NightCardError.notOpened(reason: "the create is waiting behind another Outbox entry")
        case .deferred, .aborted, .failed:
            throw NightCardError.notOpened(reason: "\(delivery.outcome)")
        }
    }

    /// Persists the two writes that complete the Night Card — the Night Summary's Managed Block and
    /// the move to the completed workflow state — in one Outbox acceptance. Nothing reaches the board
    /// here: a crash between acceptance and delivery is replayed by any later `deliverPending`.
    public func acceptCompletion(night: NightRecord) async throws -> [OutboxEntry] {
        guard let issueID = night.nightCardIssueID else {
            throw NightCardError.noNightCard(nightStart: night.nightStart)
        }
        let scope = try await NightCardScope.resolve(using: provisioning)
        let issue = BoardObjectID(rawValue: issueID)
        let findings = try authoringLines(night: night)
        let anomalies = try anomalyLines(night: night)
        let rendered = NightCardBlock.completed(
            night: night, projectID: journal.projectID, authoringFindings: findings, anomalies: anomalies
        )
        let hash = ManagedBlockFence.sha256(rendered)
        let summary = OutboxWrite(
            key: Self.summaryKey(nightStart: night.nightStart, hash: hash),
            write: .rewriteManagedBlock(issue: issue, rendered: rendered)
        )
        let complete = OutboxWrite(
            key: Self.completeKey(nightStart: night.nightStart),
            write: .updateIssue(issue: issue, change: BoardIssueChange(workflowState: scope.completedState), undo: nil)
        )
        return try outbox.accept([summary, complete])
    }

    /// Delivers whatever of the completion is still pending. A deferral (rate limit, unreachable
    /// board) is left pending on purpose — the Outbox replays it on the next Act.
    public func deliverCompletion(night: NightRecord) async throws -> OutboxDeliveryReport {
        let report = try await outbox.deliverPending()
        guard let issueID = night.nightCardIssueID else { return report }
        let completeClientID = outbox.clientID(for: Self.completeKey(nightStart: night.nightStart))
        if let delivery = report.deliveries.first(where: { $0.entry.clientID == completeClientID }),
           case .applied = delivery.outcome {
            try journal.append(
                .nightCardCompleted(issueID: issueID), act: outbox.act, runID: outbox.runID, nightID: night.id
            )
        }
        return report
    }

    /// The Waiting on You anomalies (`WaitingOnYouUnbacked`) this Night's Delta Reads found, one line
    /// each, deduplicated by issue id in the order they were first recorded.
    private func anomalyLines(night: NightRecord) throws -> [String] {
        var seen: Set<String> = []
        var lines: [String] = []
        for record in try journal.events(ofType: .waitingOnYouUnbacked) where record.nightID == night.id {
            guard case .waitingOnYouUnbacked(let issueID, _, _) = record.event else { continue }
            guard seen.insert(issueID).inserted else { continue }
            lines.append(
                "`\(issueID)` was read in Waiting on You with no Journal record behind it; it was not dispatched."
            )
        }
        return lines
    }

    /// Puts this Night's quiet authoring reasons (P9.1) on the Night Card right away, rather than
    /// waiting for completion: the author Act found a Feature already in flight, a predecessor not
    /// landed, or nothing selectable. A no-op when there is nothing new to say, or no Night Card yet
    /// recorded (this Act's own `open` failed, which would already have thrown). The rewrite's key is
    /// derived from the rendered block's hash, like the completion summary's, so a repeat of the same
    /// finding this Night (a forced re-run) is idempotent.
    public func recordAuthoring(night: NightRecord) throws {
        guard let issueID = night.nightCardIssueID else { return }
        let findings = try authoringLines(night: night)
        guard !findings.isEmpty else { return }
        let rendered = NightCardBlock.opened(night: night, projectID: journal.projectID, authoringFindings: findings)
        let hash = ManagedBlockFence.sha256(rendered)
        let write = OutboxWrite(
            key: Self.authoringKey(nightStart: night.nightStart, hash: hash),
            write: .rewriteManagedBlock(issue: BoardObjectID(rawValue: issueID), rendered: rendered)
        )
        _ = try outbox.accept(write)
    }

    /// This Night's quiet authoring reasons (P9.1), one line each, deduplicated (a forced re-run may
    /// record the same reason twice in one Night) and in the order the Journal recorded them.
    private func authoringLines(night: NightRecord) throws -> [String] {
        var seen: Set<String> = []
        var lines: [String] = []
        for record in try journal.events() where record.nightID == night.id {
            guard let line = Self.authoringLine(for: record.event) else { continue }
            guard seen.insert(line).inserted else { continue }
            lines.append(line)
        }
        return lines
    }

    private static func authoringLine(for event: JournalEvent) -> String? {
        switch event {
        case .authoringSkippedFeatureInFlight(let featureIssueID):
            return """
                Authoring was skipped: Feature `\(featureIssueID)` is already in flight for this Project. \
                A quiet Night, not a failure.
                """
        case .authoringPredecessorNotLanded(let featureIssueID, let repositories):
            let named = repositories.joined(separator: ", ")
            return """
                Authoring was skipped: predecessor Feature `\(featureIssueID)` has not landed in \(named). \
                A quiet Night, not a failure.
                """
        case .authoringNoWorkAvailable:
            return """
                Nothing was selectable to author (`AuthoringNoWorkAvailable`). A quiet Night, not a failure.
                """
        case .featureSelected(let payload):
            let repositories = payload.repositories.joined(separator: ", ")
            return "Selected Feature `\(payload.name)`, touching \(repositories)."
        case .featureAuthoringHalted(let name, let reasonKind, let detail):
            let named = detail.map { " (\($0))" } ?? ""
            return """
                Authoring halted for Feature `\(name)`: \(reasonKind)\(named). A quiet Night, not a failure.
                """
        case .featureAuthoringFailed(let name, _, let reason):
            return """
                Authoring failed for Feature `\(name)` and was rolled back: \(reason). No partial board was \
                left behind; the next author Act authors it afresh.
                """
        default:
            return nil
        }
    }
}

/// Why the Night Card could not be opened or completed.
public enum NightCardError: Error, Equatable, CustomStringConvertible {
    case notOpened(reason: String)
    case noNightCard(nightStart: NightStart)

    public var description: String {
        switch self {
        case .notOpened(let reason):
            "the Night Card was not opened: \(reason)"
        case .noNightCard(let nightStart):
            "Night \(nightStart) has no Night Card recorded to complete"
        }
    }
}
