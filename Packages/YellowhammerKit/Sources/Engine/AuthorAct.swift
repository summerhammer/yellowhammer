import Domain
import Foundation
import Journal

/// What the predecessor-ancestry gate (P9.2) found for the Feature about to be authored.
public enum PredecessorGateOutcome: Equatable, Sendable {
    /// The predecessor Feature has landed in every one of this Project's repositories — or there is
    /// no predecessor to check.
    case landed
    /// The predecessor Feature has not landed in one or more repositories: authoring must not proceed.
    case notLanded(predecessorIssueID: String, repositories: [String])
}

/// Checks whether the Feature about to be authored may proceed, given its predecessor's ancestry
/// (feature-authoring/select-the-next-feature, risks.md OQ13). The real gate is P9.2; this is the
/// injectable seam the author Act runs strictly before selecting or authoring anything.
public protocol PredecessorGate: Sendable {
    func check(_ context: ActContext) async throws -> PredecessorGateOutcome
}

/// What selecting and authoring a Feature found.
public enum FeatureAuthoringOutcome: Equatable, Sendable {
    /// A Feature was selected and authored.
    case authored
    /// Nothing was selectable to author.
    case noWorkAvailable
}

/// Selects and authors the next Feature (P9.3–P9.7). The real implementation is a later phase; this
/// is the injectable seam the author Act calls once the predecessor gate has cleared.
public protocol FeatureAuthoring: Sendable {
    func selectAndAuthor(_ context: ActContext) async throws -> FeatureAuthoringOutcome
}

/// The author Act's work (roadmap P9.1; spec: feature-authoring/select-the-next-feature, risks.md
/// OQ13), in this order:
///
/// 1. The Night Card is opened before any work — done by ``EngineInvocation/runUnderLease()``, before
///    this Act's work ever runs.
/// 2. If a Feature is already in flight for this Project (``JournalStore/inFlightFeature()`` non-nil —
///    an open Cycle, which covers a Feature returned, Blocked, or half-triaged) authoring stops here:
///    never more than one Feature in flight per Project, even when the trigger is forced or names a
///    Feature (``ActTrigger/forcedForFeature``).
/// 3. The predecessor-ancestry gate (``predecessorGate``, P9.2) runs. A predecessor not yet landed in
///    every repository stops authoring: no Worktree is allocated, nothing is dispatched, no Attempt
///    is recorded.
/// 4. Selecting and authoring the Feature (``authoring``, P9.3–P9.7) runs only once the gate clears.
/// 5. Nothing selectable to author records the Night's idle verdict
///    (``JournalStore/recordAuthoringNoWorkAvailable(nightID:act:runID:)``).
///
/// Each of steps 2, 3 and 5 is a quiet Night, not a failure: the Act returns normally (the invocation
/// records `ActEnded`) and the reason is put on the Night Card right away, before the Act's own
/// write-back.
public struct AuthorAct: Sendable {
    /// The predecessor-ancestry gate (P9.2); nil is treated as `.landed` — there is no gate to fail
    /// yet, so authoring is never blocked on a check that has not landed.
    public let predecessorGate: (any PredecessorGate)?
    /// Selects and authors the next Feature (P9.3–P9.7); nil keeps this Act's public behaviour of
    /// throwing `notImplemented` once the gate has cleared, so production never falsely records an
    /// idle verdict before selection exists.
    public let authoring: (any FeatureAuthoring)?

    public init(predecessorGate: (any PredecessorGate)? = nil, authoring: (any FeatureAuthoring)? = nil) {
        self.predecessorGate = predecessorGate
        self.authoring = authoring
    }

    public var work: EngineInvocation.ActWork {
        { context in try await self.run(context) }
    }

    public func run(_ context: ActContext) async throws {
        let journal = context.journal

        if let (feature, _) = try journal.inFlightFeature() {
            try journal.append(
                .authoringSkippedFeatureInFlight(featureIssueID: feature.issueID),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            try await writeBack(context: context)
            return
        }

        switch try await checkPredecessorGate(context: context) {
        case .notLanded(let predecessorIssueID, let repositories):
            try journal.append(
                .authoringPredecessorNotLanded(featureIssueID: predecessorIssueID, repositories: repositories),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            try await writeBack(context: context)
            return
        case .landed:
            break
        }

        guard let authoring else {
            throw EngineInvocationError.notImplemented(.author)
        }

        switch try await authoring.selectAndAuthor(context) {
        case .noWorkAvailable:
            try journal.recordAuthoringNoWorkAvailable(
                nightID: context.night.id, act: context.act, runID: context.runID
            )
        case .authored:
            break
        }
        try await writeBack(context: context)
    }

    private func checkPredecessorGate(context: ActContext) async throws -> PredecessorGateOutcome {
        guard let predecessorGate else { return .landed }
        return try await predecessorGate.check(context)
    }

    /// Puts a quiet reason (or the idle verdict) on the Night Card right away, then delivers pending
    /// Outbox entries. A deferred or failed delivery of that rewrite must not fail the Act — the
    /// Outbox replays it on a later Act.
    private func writeBack(context: ActContext) async throws {
        if let nightCard = context.nightCard {
            try nightCard.recordAuthoring(night: context.night)
        }
        guard let outbox = context.outbox else { return }
        _ = try await outbox.deliverPending()
    }
}
