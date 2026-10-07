import Domain
import Foundation
import Journal

/// Creates and completes one Project's current unarchived Night Card through the Outbox, so an
/// interrupted and resumed Act cannot duplicate it (spec: open-and-close-the-night-card).
public struct NightCardMaintenance: Sendable {
    // `Bounds` — the three Project-scoped values the Night Summary reports proximity to (roadmap
    // P11.6) — lives in NightCardMaintenance+Bounds.swift, split out to keep this struct under the
    // type body length limit.

    public let journal: JournalStore
    public let outbox: Outbox
    /// Resolved into a ``NightCardScope`` only when a board write actually needs it — never cached,
    /// so an Act with a live Night Card needs no provisioning reads.
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

    public static func summaryKey(nightStart: NightStart, issueID: String, hash: String) -> String {
        "night-card:\(nightStart):\(issueID):summary:\(hash)"
    }

    public static func completeKey(nightStart: NightStart, issueID: String) -> String {
        "night-card:\(nightStart):\(issueID):complete"
    }

    public static func authoringKey(nightStart: NightStart, issueID: String, hash: String) -> String {
        "night-card:\(nightStart):\(issueID):authoring:\(hash)"
    }

    /// The Outbox key for the comment an Act's halt writes to the Night Card (roadmap P12.5):
    /// one per Act run, so a heartbeat-lost and reclaimed run's halt cannot collide with the run
    /// that reclaimed it.
    public static func haltedKey(nightStart: NightStart, issueID: String, runID: RunID) -> String {
        "night-card:\(nightStart):\(issueID):halted:\(runID)"
    }

    public enum Opening: Equatable, Sendable {
        /// The recorded Night Card is live; nothing was written.
        case alreadyRecorded(issueID: String)
        /// A Night Card was recorded. `replayed` is true when the board had already applied the
        /// create — a resumed Act finding what a killed one already did.
        case opened(issueID: String, replayed: Bool)
    }

    /// Reads the current archive state before any Night Card write, retaining every predecessor.
    /// Each predecessor gives the replacement its own deterministic Outbox key across interrupted Acts.
    public func open(night: NightRecord) async throws -> Opening {
        var current = try journal.night(id: night.id) ?? night
        var created: Opening?
        while true {
            let predecessor: BoardObject?
            if let existing = current.nightCardIssueID {
                let object = try await outbox.reading?.issue(BoardObjectID(rawValue: existing))
                guard let object, object.archivedAt != nil else {
                    return created ?? .alreadyRecorded(issueID: existing)
                }
                predecessor = object
            } else { predecessor = nil }
            created = try await create(night: current, predecessor: predecessor)
            current = try journal.night(id: current.id) ?? current
        }
    }

    private func create(night: NightRecord, predecessor: BoardObject?) async throws -> Opening {
        guard let act = outbox.act else {
            throw NightCardError.notOpened(reason: "the Outbox has no Act to stamp the Night Card with")
        }
        let scope = try await NightCardScope.resolve(using: provisioning)
        let key = predecessor.map { Self.replacementKey(nightStart: night.nightStart, predecessor: $0.id.rawValue) }
            ?? Self.createKey(nightStart: night.nightStart)
        var description = ManagedBlockFence.initialDescription(
            rendered: NightCardBlock.opened(night: night, projectID: journal.projectID)
        )
        if let predecessor {
            description += "\n\nReplaces archived Night Card [\(predecessor.key)](\(predecessor.url))."
        }
        let draft = BoardIssueDraft(
            team: scope.team, title: "Night \(night.nightStart)", description: description,
            labels: [scope.nightCardLabel]
        )
        let delivery = try await outbox.post(OutboxWrite(key: key, write: .createIssue(draft, parentKey: nil)))
        let issueID: String
        let replayed: Bool
        switch delivery.outcome {
        case .applied(let id):
            guard let id else { throw NightCardError.notOpened(reason: "the board create returned no id") }
            issueID = id.rawValue
            replayed = false
        case .alreadyApplied(let id):
            issueID = id.rawValue
            replayed = true
        case .deferred(.behindAnotherEntry), .aborted:
            guard let entry = try journal.outboxEntry(clientID: outbox.clientID(for: key)),
                  entry.state == .applied || entry.state == .aborted, let result = entry.result else {
                throw NightCardError.notOpened(reason: "\(delivery.outcome)")
            }
            issueID = result
            replayed = true
        case .deferred, .failed:
            throw NightCardError.notOpened(reason: "\(delivery.outcome)")
        }
        if let predecessor {
            try journal.replaceNightCard(id: night.id, predecessorIssueID: predecessor.id.rawValue,
                issueID: issueID, act: act, runID: outbox.runID)
        } else {
            try journal.recordNightCard(id: night.id, issueID: issueID, act: act, runID: outbox.runID)
        }
        return .opened(issueID: issueID, replayed: replayed)
    }

    public static func replacementKey(nightStart: NightStart, predecessor: String) -> String {
        "night-card:\(nightStart):replace:\(predecessor)"
    }

    /// Persists the two writes that complete the Night Card — the Night Summary's Managed Block and
    /// the move to the completed workflow state — in one Outbox acceptance. Nothing reaches the board
    /// here: a crash between acceptance and delivery is replayed by any later `deliverPending`.
    public func acceptCompletion(night: NightRecord) async throws -> [OutboxEntry] {
        _ = try await open(night: night)
        let night = try journal.night(id: night.id) ?? night
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
            key: Self.summaryKey(nightStart: night.nightStart, issueID: issueID, hash: hash),
            write: .rewriteManagedBlock(issue: issue, rendered: rendered)
        )
        let complete = OutboxWrite(
            key: Self.completeKey(nightStart: night.nightStart, issueID: issueID),
            write: .updateIssue(issue: issue, change: BoardIssueChange(workflowState: scope.completedState), undo: nil)
        )
        return try outbox.accept([summary, complete])
    }

    /// Delivers whatever of the completion is still pending. A deferral (rate limit, unreachable
    /// board) is left pending on purpose — the Outbox replays it on the next Act.
    public func deliverCompletion(night: NightRecord) async throws -> OutboxDeliveryReport {
        let report = try await outbox.deliverPending()
        let night = try journal.night(id: night.id) ?? night
        guard let issueID = night.nightCardIssueID else { return report }
        let completeClientID = outbox.clientID(for: Self.completeKey(nightStart: night.nightStart, issueID: issueID))
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
