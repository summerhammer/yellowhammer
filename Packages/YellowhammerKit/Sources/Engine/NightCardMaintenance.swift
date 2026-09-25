import Domain
import Foundation
import Journal

/// Creates and completes one Project's Night Card, through the Outbox like every other board write —
/// so a crashed and resumed Act cannot create two (spec: open-and-close-the-night-card).
public struct NightCardMaintenance: Sendable {
    // `Bounds` — the three Project-scoped values the Night Summary reports proximity to (roadmap
    // P11.6) — lives in NightCardMaintenance+Bounds.swift, split out to keep this struct under the
    // type body length limit.

    public let journal: JournalStore
    public let outbox: Outbox
    /// Resolved into a ``NightCardScope`` only when a board write actually needs it — never cached,
    /// so a build Act of a Night whose card already exists reads nothing from the board.
    public let provisioning: any BoardProvisioning
    public let bounds: Bounds

    public init(
        journal: JournalStore, outbox: Outbox, provisioning: any BoardProvisioning, bounds: Bounds = Bounds()
    ) {
        self.journal = journal
        self.outbox = outbox
        self.provisioning = provisioning
        self.bounds = bounds
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

    /// The Outbox key for the comment an Act's halt writes to the Night Card (roadmap P12.5):
    /// one per Act run, so a heartbeat-lost and reclaimed run's halt cannot collide with the run
    /// that reclaimed it.
    public static func haltedKey(nightStart: NightStart, runID: RunID) -> String {
        "night-card:\(nightStart):halted:\(runID)"
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
        let verdict = try NightSummary.verdictLine(night: night, journal: journal)
        let findings = try authoringLines(night: night)
        let cardLines = try NightSummary.cardLines(night: night, journal: journal)
        let dispositionLines = try NightSummary.dispositionLines(night: night, journal: journal)
        let pullRequestLines = try NightSummary.pullRequestLines(night: night, journal: journal)
        let answerLines = try NightSummary.answerLines(night: night, journal: journal)
        let anomalies = try NightSummary.anomalyLines(night: night, journal: journal)
        let crashesAndReclaims = try NightSummary.crashesAndReclaimsLines(night: night, journal: journal)
        let leftoverProcesses = try NightSummary.leftoverProcessLines(night: night, journal: journal)
        let exceptions = try NightSummary.exceptionLines(night: night, journal: journal)
        let boundsLines = try self.boundsLines(night: night)
        let standingItems = try standingItemLines()
        let unadoptedCards = try NightSummary.unadoptedCardLines(night: night, journal: journal)
        let inFlightFeature = try NightSummary.inFlightFeatureLines(night: night, journal: journal)
        let instrumentedRates = try NightSummary.instrumentedRateLines(night: night, journal: journal, bounds: bounds)
        let rendered = NightCardBlock.completed(
            night: night, projectID: journal.projectID, verdictLine: verdict, authoringFindings: findings,
            cardLines: cardLines, dispositionLines: dispositionLines, pullRequestLines: pullRequestLines,
            answerLines: answerLines, anomalies: anomalies, crashesAndReclaims: crashesAndReclaims,
            leftoverProcesses: leftoverProcesses,
            exceptions: exceptions, bounds: boundsLines, standingItems: standingItems,
            unadoptedCards: unadoptedCards, inFlightFeature: inFlightFeature,
            instrumentedRates: instrumentedRates
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

    // `anomalyLines(night:journal:)`, `crashesAndReclaimsLines(night:journal:)`,
    // `exceptionLines(night:journal:)`, `unadoptedCardLines(night:journal:)`,
    // `leftoverProcessLines(night:journal:)` and `inFlightFeatureLines(night:journal:)` — which folds
    // the old, per-Night `**Mainline Conflicts:**` section into the standing unmerged-in-flight-Feature
    // line — live on `NightSummary` (NightSummary+Exceptions.swift, NightSummary+Leftovers.swift,
    // NightSummary+StandingLines.swift).

    // `boundsLines(night:)` and `standingItemLines()` live in NightCardMaintenance+Bounds.swift.
    // `recordAuthoring(night:)`, `authoringLines(night:)`, `authoringLine(for:)` and
    // `authoringFaultLine(feature:reason:)` — the P9.1 quiet-authoring-reasons section — live in
    // NightCardMaintenance+Authoring.swift. Both split out to keep this file/type under their limits.
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
