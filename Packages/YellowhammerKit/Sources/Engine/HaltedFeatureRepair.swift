import Domain
import Foundation
import Journal

/// Repairing an existing halted Feature (roadmap P22.5; spec: feature-authoring/select-the-next-feature,
/// `#halted-authoring-repair`). An Authoring Halt is a durable checkpoint on one known Feature, not a new intake
/// lane: the Operator repairs that Feature Card and moves it to Todo, and the next author Act validates and resumes
/// the SAME Feature under the SAME Feature Issue instead of authoring a duplicate (yellowhammer-spec#113).
///
/// This file is the board-facing half; the Journal half is ``AuthoringHaltCheckpoint``, and the resume itself is
/// ``FeatureSelection/resumeRepairedHalt(_:)``.
///
/// - ``observe(context:)`` runs in the author Act after the complete Delta Read and before the unanswered-Nights
///   clock: it reads each tracked halted Feature Card, keeps its workflow state as the durable condition for every
///   state write this Act goes on to make, records the Operator's move into Todo as one pending request, and
///   resolves a Feature Card completed or canceled before any Cycle as that terminal disposition.
/// - ``deferPending(reason:context:)`` answers a pending request the Act cannot act on (another Feature is in
///   flight, the predecessor has not landed) with one comment per reason, leaving the Feature as the Operator set it.
/// - Todo never clears a halt: only a durably accepted plan does.
enum HaltedFeatureRepair {
    // MARK: - Observing

    static func observe(context: ActContext) async throws {
        guard let board = context.board else { return }
        let journal = context.journal
        let scope = try await BoardStateScope.resolve(using: board)
        for halt in try journal.liveAuthoringHalts() {
            guard let issueID = halt.issueID, let feature = FeatureName(rawValue: halt.featureName),
                  let checkpoint = try journal.authoringHaltCheckpoint(haltID: halt.id),
                  checkpoint.boardConnection == journal.linearWorkspace.rawValue,
                  try !isHeldByRefusal(issueID: issueID, journal: journal),
                  let object = try await board.reading.issue(BoardObjectID(rawValue: issueID)),
                  object.archivedAt == nil, !object.isTrashed
            else { continue }
            // A halt whose draft children were not all posted (a crash between the checkpoint and the creates)
            // finishes posting them here (roadmap P22.6); a draft already created is never created again.
            try await HaltDrafts.ensurePosted(halt: halt, context: context)
            try journal.recordAuthoringHaltObservation(
                haltID: halt.id, stateID: object.workflowState.id.rawValue, category: object.workflowState.category,
                revision: object.updatedAt, authoritative: true
            )
            switch FeatureDisposition(workflowState: object.workflowState, scope: scope) {
            case .ready:
                try journal.requestAuthoringRepair(
                    haltID: halt.id, feature: feature, nightID: context.night.id, act: context.act,
                    runID: context.runID
                )
            case .completed:
                try resolveTerminal(feature: feature, disposition: "completed", context: context)
            case .canceled:
                try resolveTerminal(feature: feature, disposition: "canceled", context: context)
            case .backlog, .continuing, .waitingOnYou, .blocked, .indeterminate:
                if checkpoint.repairPending { try journal.withdrawAuthoringRepairRequest(haltID: halt.id) }
            }
        }
    }

    /// A Refusal's own lifecycle answers by citation: a Feature Issue it sits on is never repaired by Todo.
    private static func isHeldByRefusal(issueID: String, journal: JournalStore) throws -> Bool {
        try journal.allRefusals().contains { $0.issueID == issueID && ($0.state == .open || $0.state == .expired) }
    }

    /// The halt resolves as the Feature Card's native terminal disposition: no Cycle, no dispatch, no delivery or
    /// merge claim, and no Board write — the Operator's own state stays.
    static func resolveTerminal(feature: FeatureName, disposition: String, context: ActContext) throws {
        try context.journal.recordAuthoringRepairStep(
            feature: feature, step: "terminal", detail: disposition,
            nightID: context.night.id, act: context.act, runID: context.runID
        )
        try context.journal.resolveAuthoringHalt(
            feature: feature, nightID: context.night.id, act: context.act, runID: context.runID
        )
    }

    /// Reads a halted Feature Card again just before a plan that continues it is accepted (the plan's own write
    /// belongs to a group and cannot be conditioned, so this read is the guard). Returns the outcome to stop with,
    /// or nil to accept.
    ///
    /// - A Feature Card the Operator completed or canceled meanwhile is theirs: nothing is accepted and the halt
    ///   resolves as that terminal disposition.
    /// - For the Operator's repair request, a Feature Card that is no longer in Todo moved during validation:
    ///   nothing is accepted, the request stays unhandled and the next Act reads the board again.
    /// - Otherwise the admitted revision is recorded in the Journal.
    static func revalidateBeforeAcceptance(
        _ plan: AuthoringPlan, context: ActContext
    ) async throws -> FeatureAuthoringOutcome? {
        guard let issue = plan.reusedFeatureIssue, let feature = FeatureName(rawValue: plan.record.name),
              let board = context.board, let object = try await board.reading.issue(issue)
        else { return nil }
        let scope = try await BoardStateScope.resolve(using: board)
        let disposition = FeatureDisposition(workflowState: object.workflowState, scope: scope)
        if let halt = try context.journal.liveAuthoringHalts().first(where: { $0.issueID == issue.rawValue }) {
            try context.journal.recordAuthoringHaltObservation(
                haltID: halt.id, stateID: object.workflowState.id.rawValue, category: object.workflowState.category,
                revision: object.updatedAt, authoritative: true
            )
        }
        switch disposition {
        case .completed:
            try resolveTerminal(feature: feature, disposition: "completed", context: context)
            return .halted
        case .canceled:
            try resolveTerminal(feature: feature, disposition: "canceled", context: context)
            return .halted
        default:
            break
        }
        let journal = context.journal
        guard let halt = try journal.liveAuthoringHalts().first(where: { $0.issueID == issue.rawValue }),
              try journal.authoringHaltCheckpoint(haltID: halt.id)?.hasUnhandledRepairRequest == true
        else { return nil }
        guard disposition == .ready else {
            try journal.recordAuthoringRepairStep(
                feature: feature, step: "deferred", detail: "the Feature Card moved during validation",
                nightID: context.night.id, act: context.act, runID: context.runID
            )
            return .authoringPending
        }
        var detail = "Feature Card revision \(ISO8601DateFormatter().string(from: object.updatedAt))"
        if let snapshot = plan.repairSnapshot {
            guard let admitted = try await admit(snapshot, feature: feature, issue: issue, context: context) else {
                return .authoringPending
            }
            detail += admitted
        }
        try journal.recordAuthoringRepairStep(
            feature: feature, step: "admitted", detail: detail,
            nightID: context.night.id, act: context.act, runID: context.runID
        )
        return nil
    }

    // MARK: - Deferring

    /// Answers every pending, unhandled request this Act cannot act on: one comment per halt and reason, once, and
    /// nothing else — the Feature stays as the Operator set it, nothing is dispatched or accepted.
    static func deferPending(reason: DeferralReason, context: ActContext) async throws {
        let journal = context.journal
        for halt in try journal.liveAuthoringHalts() {
            guard let issueID = halt.issueID, let feature = FeatureName(rawValue: halt.featureName),
                  let checkpoint = try journal.authoringHaltCheckpoint(haltID: halt.id),
                  checkpoint.hasUnhandledRepairRequest
            else { continue }
            let key = commentKey(halt: halt, seq: checkpoint.repairSeq, kind: "deferred:\(reason.key)")
            let posted = try await postCommentOnce(
                key: key, issue: BoardObjectID(rawValue: issueID), body: reason.feedback(for: feature), context: context
            )
            if posted {
                try journal.recordAuthoringRepairStep(
                    feature: feature, step: "deferred", detail: reason.key,
                    nightID: context.night.id, act: context.act, runID: context.runID
                )
            }
        }
    }

    enum DeferralReason {
        case featureInFlight
        case predecessorNotLanded
        case unmergedStackFull

        var key: String {
            switch self {
            case .featureInFlight: "feature-in-flight"
            case .predecessorNotLanded: "predecessor-not-landed"
            case .unmergedStackFull: "unmerged-stack-full"
            }
        }

        func feedback(for feature: FeatureName) -> String {
            switch self {
            case .featureInFlight:
                """
                Repair of Feature '\(feature)' is deferred: another Feature is in flight for this Project, and only \
                one Feature is in flight at a time. The Feature stays as you set it; it is validated on a later \
                author Act once the slot is free.
                """
            case .predecessorNotLanded:
                """
                Repair of Feature '\(feature)' is deferred: the predecessor Feature has not landed yet. The Feature \
                stays as you set it; it is validated on a later author Act once the predecessor has landed.
                """
            case .unmergedStackFull:
                """
                Repair of Feature '\(feature)' is deferred: the unmerged Feature stack has reached \
                unmerged_features_max, so no Feature is authored until one of them merges. The Feature stays as you \
                set it; it is validated on a later author Act once a merge is observed.
                """
            }
        }
    }

    // MARK: - Feedback and restoring

    static func commentKey(halt: AuthoringHaltRecord, seq: Int, kind: String) -> String {
        "feature:\(halt.featureName):authoring-halt:\(halt.id):repair:\(seq):\(kind)"
    }

    /// Posts `body` under `key` unless the Journal already holds that comment; true when this call accepted it.
    @discardableResult
    static func postCommentOnce(
        key: String, issue: BoardObjectID, body: String, context: ActContext
    ) async throws -> Bool {
        guard let outbox = context.outbox else { return false }
        if try context.journal.outboxEntry(clientID: outbox.clientID(for: key)) != nil { return false }
        _ = try await outbox.post(OutboxWrite(key: key, write: .createComment(issue: issue, body: body)))
        return true
    }

    /// An invalid or empty repair leaves the Feature as halted as it was: Waiting on You, or — when the halt had
    /// already expired — Blocked, never a fresh position and never a renewed clock. The write is decided against
    /// the Todo the Operator set, so a newer human state (or a terminal one) is never overwritten.
    static func restoreHaltedPosition(
        halt: AuthoringHaltRecord, seq: Int, todo: BoardWorkflowState, context: ActContext
    ) async throws {
        guard let outbox = context.outbox, let board = context.board, let issueID = halt.issueID else { return }
        let scope = try await BoardStateScope.resolve(using: board)
        let target: CardState = halt.state == .expired ? .blocked : .waitingOnYou
        var change = scope.labels.change(cardType: .featureCard)
        change.workflowState = try scope.id(for: target)
        _ = try await outbox.post(OutboxWrite(
            key: commentKey(halt: halt, seq: seq, kind: "restore"),
            write: .updateIssue(issue: BoardObjectID(rawValue: issueID), change: change, undo: nil),
            expectedState: todo.id
        ))
        try context.journal.recordAuthoringHaltObservation(
            haltID: halt.id, stateID: try scope.id(for: target).rawValue, category: .started, revision: Date()
        )
    }
}
