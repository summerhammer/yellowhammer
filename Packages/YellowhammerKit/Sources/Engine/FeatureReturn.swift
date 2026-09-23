import Domain
import Foundation
import Journal

/// Why a Feature could not be returned: the land Act records it and the Cycle stays unlanded so the next
/// firing retries.
public struct FeatureReturnFault: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// Returns a Feature with unmet or unresolved clauses to the Operator (roadmap P10.6; spec: verification/
/// return-a-feature-with-unmet-clauses), the real ``FeatureReturning``. Called only when Verification's
/// verdict is not all-met, after every lane's pull request has opened.
///
/// The Feature is never moved to Done and its Cycle is never archived — this seam does neither. Pull
/// requests already opened are read, never written: landing is not reversed by a failed verification.
/// Idempotent across a retried land Act: the Journal transition and the Outbox writes it queues are all
/// keyed so a repeat run changes nothing.
public struct FeatureReturn: FeatureReturning, Sendable {
    public init() { }

    public func returnFeature(_ context: LandActFeatureContext, verdict: VerificationVerdict) async throws {
        let journal = context.act.journal
        guard let recorded = try journal.featureVerification(cycleID: context.cycleID) else {
            throw FeatureReturnFault(reason: "the Cycle has no recorded Verification to return the Feature with")
        }

        let firstReturn = try journal.recordFeatureReturned(featureID: context.feature.id, runID: context.act.runID)
        if firstReturn {
            let unmet = recorded.clauses.filter { $0.verdict == .unmet }.count
            let unresolved = recorded.clauses.filter { $0.verdict == .unresolved }.count
            try journal.append(
                .featureReturned(
                    cycleID: context.cycleID, featureIssueID: context.feature.issueID, unmet: unmet,
                    unresolved: unresolved
                ),
                act: context.act.act, runID: context.act.runID, nightID: context.act.night.id
            )
        }

        try await postWaitingOnYou(context: context)
        try await postComment(recorded, context: context)
    }

    /// Moves the Feature Issue to Waiting on You, through the board projection, with whatever assignee
    /// the Operator identity resolves to right now — nil when unconfigured or no longer an active
    /// workspace member, in which case the state is still written with no assignee.
    private func postWaitingOnYou(context: LandActFeatureContext) async throws {
        guard let outbox = context.act.outbox, let board = context.act.board else { return }
        let scope = try await BoardStateScope.resolve(using: board.provisioning)
        let issue = BoardObjectID(rawValue: context.feature.issueID)
        let assignee = await context.act.operatorIdentity.assignee(on: board.reading)

        let projection = BoardStateProjection(journal: context.act.journal, outbox: outbox, scope: scope)
        _ = try await projection.transition(featureIssue: issue, to: .waitingOnYou, operator: assignee)
    }

    /// Posts the return comment, keyed so a retried land Act queues the same write again rather than a
    /// second comment.
    private func postComment(_ recorded: FeatureVerificationRecord, context: LandActFeatureContext) async throws {
        guard let outbox = context.act.outbox else { return }
        let pullRequests = try context.act.journal.pullRequests(featureID: context.feature.id)
        let body = FeatureReturnComment(record: recorded, pullRequests: pullRequests).body()
        let key = "land:\(context.cycleID):return:\(context.feature.issueID)"
        let issue = BoardObjectID(rawValue: context.feature.issueID)
        _ = try await outbox.post(OutboxWrite(key: key, write: .createComment(issue: issue, body: body)))
    }
}
