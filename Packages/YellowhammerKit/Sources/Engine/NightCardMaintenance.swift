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
        let conflicts = try mainlineConflictLines(night: night)
        let rendered = NightCardBlock.completed(
            night: night, projectID: journal.projectID, authoringFindings: findings, anomalies: anomalies,
            mainlineConflicts: conflicts
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

    /// The standing Mainline Conflict line is recomputed from this Night's immutable Journal events.
    private func mainlineConflictLines(night: NightRecord) throws -> [String] {
        var seen: Set<String> = []
        var lines: [String] = []
        for record in try journal.events(ofType: .mainlineConflictDetected)
            where record.nightID == night.id {
            guard case .mainlineConflictDetected(let feature, let repository, let paths) = record.event else {
                continue
            }
            let pathText = paths.isEmpty ? "paths unavailable" : paths.joined(separator: ", ")
            let line = "Feature `\(feature)` — `\(repository)`: \(pathText) " +
                "(detected as of Night \(night.nightStart); reported only, never gates landing)."
            guard seen.insert(line).inserted else { continue }
            lines.append(line)
        }
        return lines
    }

    /// Puts this Night's quiet authoring reasons (P9.1) on the Night Card right away, rather than
    /// waiting for completion: the author Act found a Feature already in flight, a predecessor not
    /// landed, or nothing selectable. A no-op when there is no Night Card yet recorded (this Act's own
    /// `open` failed, which would already have thrown). Rendered fresh from every recorded finding each
    /// time it runs — never incrementally — so an accepted-but-undelivered line (roadmap P9.10) that
    /// resolves later in the same Night disappears on the next Act's render. The rewrite's key is
    /// derived from the rendered block's hash, like the completion summary's, so a repeat of the same
    /// findings this Night (a forced re-run, or nothing new to say) is idempotent.
    public func recordAuthoring(night: NightRecord) throws {
        guard let issueID = night.nightCardIssueID else { return }
        let findings = try authoringLines(night: night)
        let rendered = NightCardBlock.opened(night: night, projectID: journal.projectID, authoringFindings: findings)
        let hash = ManagedBlockFence.sha256(rendered)
        let write = OutboxWrite(
            key: Self.authoringKey(nightStart: night.nightStart, hash: hash),
            write: .rewriteManagedBlock(issue: BoardObjectID(rawValue: issueID), rendered: rendered)
        )
        _ = try outbox.accept(write)
    }

    /// This Night's quiet authoring reasons (P9.1), one line each, deduplicated (a forced re-run may
    /// record the same reason twice in one Night) and in the order the Journal recorded them — plus, for
    /// every `featureAuthoringAccepted` plan this Night with no later `featureAuthored` /
    /// `featureAuthoringFailed` for the same group key, a line saying the board is still being written
    /// (roadmap P9.10): decided here, not in ``authoringLine(for:)`` alone, because whether a plan is
    /// still pending depends on the *rest* of this Night's events — so the line disappears on a later
    /// render of the same Night once the plan resolves.
    private func authoringLines(night: NightRecord) throws -> [String] {
        var seen: Set<String> = []
        var lines: [String] = []
        var acceptedOrder: [String] = []
        var acceptedPlans: [String: FeatureAuthoringAcceptedPayload] = [:]
        var resolvedGroupKeys: Set<String> = []
        for record in try journal.events() where record.nightID == night.id {
            if let line = Self.authoringLine(for: record.event), seen.insert(line).inserted {
                lines.append(line)
            }
            switch record.event {
            case .featureAuthoringAccepted(let plan):
                if acceptedPlans[plan.groupKey] == nil { acceptedOrder.append(plan.groupKey) }
                acceptedPlans[plan.groupKey] = plan
            case .featureAuthored(let payload):
                resolvedGroupKeys.insert(payload.groupKey)
            case .featureAuthoringFailed(_, let groupKey, _):
                resolvedGroupKeys.insert(groupKey)
            default:
                break
            }
        }
        for groupKey in acceptedOrder where !resolvedGroupKeys.contains(groupKey) {
            guard let plan = acceptedPlans[groupKey] else { continue }
            lines.append("""
                Authoring Feature `\(plan.name)` was accepted onto the board but is not yet fully \
                delivered: the board is still being written. Not a halt.
                """)
        }
        return lines
    }

    // One case per authoring-line event: a growing enumeration, not a complexity problem to refactor.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func authoringLine(for event: JournalEvent) -> String? {
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
        case .authoringPredecessorIndeterminate(let featureIssueID, let repositories):
            let named = repositories.joined(separator: ", ")
            return """
                Authoring was skipped: predecessor Feature `\(featureIssueID)`'s Feature Branch could not be \
                found in \(named). A quiet Night, not a failure.
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
        case .refusalOpened(let name, _, let clauses, let depth),
            .refusalRepeated(let name, _, let clauses, let depth):
            let named = clauses.isEmpty ? "" : " Uncitable clauses: \(clauses)."
            return """
                Feature `\(name)` was refused: its specification was too thin to cite a Definition of \
                Done.\(named) Re-selection depth: \(depth). A quiet Night, not a failure.
                """
        case .featureAuthoringFailed(let name, _, let reason), .featureBreakdownRejected(let name, let reason):
            return authoringFaultLine(feature: name, reason: reason)
        case .featureClosedByMerge(_, let featureIssueID, let repositories, let carriedForward, _, _):
            let named = repositories.joined(separator: ", ")
            return """
                Feature `\(featureIssueID)` closed by merge: its Feature Branches reached mainline in \
                \(named). Its Cycle is archived unverified; \(carriedForward.count) Cards carried forward, \
                Blocked awaiting Adoption.
                """
        case .featureSelectionFailed(let reason):
            return """
                Selecting a Feature failed: \(reason). Nothing was written to the board, so there is no \
                Feature card to open and nothing to answer; the author Act stood down without authoring. \
                The next author Act selects afresh.
                """
        default:
            return nil
        }
    }

    /// The exception wording an authoring fault reads as (roadmap P9.10): a rolled-back Outbox group
    /// and a breakdown validation rejection say exactly the same thing — neither ever wrote to the
    /// board, so there is no Feature card to open and nothing to answer, and the author Act stood down
    /// without authoring. Never "halt"; never "A quiet Night, not a failure" (that phrase is reserved
    /// for a quiet skip, not a fault).
    private static func authoringFaultLine(feature name: String, reason: String) -> String {
        """
        Authoring Feature `\(name)` failed: \(reason). Nothing was written to the board, so there is no \
        Feature card to open and nothing to answer; the author Act stood down without authoring. The \
        next author Act authors it afresh.
        """
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
