import Domain
import Foundation
import Journal

/// Everything an Act's work is handed: the one Project's Journal and this run's identity. There is
/// nothing else to hand it — a resumed Act rebuilds Attempt and Round counts, routes tried and
/// Worktree paths from the Journal, and an invocation holds nothing in memory between Acts.
public struct ActContext: Sendable {
    public let act: Act
    public let mode: NightMode
    public let trigger: ActTrigger
    public let runID: RunID
    public let journal: JournalStore
}

/// One Act's work for one Project, then exit.
///
/// An invocation is handed exactly one Project's Journal and holds no other: the Engine never opens
/// a Journal (module boundary rule MB5), so nothing in it can name a sibling Project's. Two Acts of
/// the same Project must not run at once, so the invocation claims the Project's Act-scoped lease
/// before doing anything and stands down, out loud, when another run holds it. `run()` returns only
/// after the heartbeat task has ended (the task group is structured), so nothing — no timer, no task,
/// no cache — outlives the invocation; the process exits after `run()` returns.
public struct EngineInvocation: Sendable {
    public typealias ActWork = @Sendable (ActContext) async throws -> Void

    public let act: Act
    public let mode: NightMode
    public let trigger: ActTrigger
    public let runID: RunID
    public let leasePolicy: LeasePolicy
    private let journal: JournalStore
    private let work: ActWork

    public init(
        act: Act,
        mode: NightMode,
        journal: JournalStore,
        trigger: ActTrigger = .scheduled,
        runID: RunID = RunID(),
        leasePolicy: LeasePolicy = .ruled
    ) {
        self.act = act
        self.mode = mode
        self.trigger = trigger
        self.journal = journal
        self.runID = runID
        self.leasePolicy = leasePolicy
        self.work = { _ in throw EngineInvocationError.notImplemented(act) }
    }

    /// The Act's work under the lease is injectable so a test can drive an Act that completes;
    /// the real Acts arrive in later phases, and until then the public initializer's work throws
    /// `notImplemented`.
    internal init(
        act: Act,
        mode: NightMode,
        journal: JournalStore,
        trigger: ActTrigger = .scheduled,
        runID: RunID = RunID(),
        leasePolicy: LeasePolicy = .ruled,
        work: @escaping ActWork
    ) {
        self.act = act
        self.mode = mode
        self.trigger = trigger
        self.journal = journal
        self.runID = runID
        self.leasePolicy = leasePolicy
        self.work = work
    }

    /// The Project this invocation is scoped to: the one whose Journal it was given.
    public var projectID: ProjectID { journal.projectID }

    public func run() async throws {
        // A Feature name is only meaningful for the author Act.
        if case .forcedForFeature = trigger, act != .author {
            throw EngineInvocationError.featureNamedForNonAuthoringAct(act)
        }
        // Every step of the Act's life is appended to the Project's event log, so the Night Summary
        // can be computed from it. The records are written under the lease, before it is released,
        // and best-effort: failing to write one must not fail the Act, or stop it standing down.
        switch try journal.claimActLease(act: act, runID: runID, mode: mode, policy: leasePolicy) {
        case .held(let holder):
            _ = try? journal.append(.actStoodDown(holder: holder), act: act, runID: runID)
            throw EngineInvocationError.actLeaseHeld(act: act, projectID: projectID, by: holder)
        case .claimed:
            _ = try? journal.append(.actStarted, act: act, runID: runID)
        }
        // Evaluate the trigger predicate under the lease.
        let predicateOutcome = try ActTriggerPredicate.evaluate(act: act, trigger: trigger, journal: journal)
        if case .notMet(let reason) = predicateOutcome {
            _ = try? journal.append(.actIdle(reason: reason), act: act, runID: runID)
            _ = try? journal.append(.actEnded, act: act, runID: runID)
            try journal.releaseActLease(runID: runID)
            return
        }

        let context = ActContext(act: act, mode: mode, trigger: trigger, runID: runID, journal: journal)
        do {
            try await withLeaseHeartbeat(
                every: leasePolicy.heartbeatDuration,
                beat: { try journal.heartbeatActLease(runID: runID, policy: leasePolicy) },
                body: { try await work(context) }
            )
            _ = try? journal.append(.actEnded, act: act, runID: runID)
        } catch {
            // An Act that cannot complete records why, where it can, before exiting. The Act's failure
            // is the error worth reporting: if the release fails too, the lease frees by its TTL,
            // exactly as it would after a crash.
            _ = try? journal.append(.actIncomplete(reason: String(describing: error)), act: act, runID: runID)
            _ = try? journal.releaseActLease(runID: runID)
            throw error
        }
        try journal.releaseActLease(runID: runID)
    }
}

public enum EngineInvocationError: Error, Sendable, Equatable {
    case notImplemented(Act)
    /// Another run of the same Project holds its Act-scoped lease. This Act stood down and ran nothing.
    case actLeaseHeld(act: Act, projectID: ProjectID, by: ActLease)
    /// A Feature name was provided for a non-authoring Act. No lease is taken.
    case featureNamedForNonAuthoringAct(Act)
}

extension EngineInvocationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notImplemented(let act):
            return "Act '\(act.rawValue)' is not implemented"
        case .actLeaseHeld(let act, let projectID, let holder):
            return """
                The \(act.rawValue) Act for Project '\(projectID)' stood down: run \(holder.runID) has held the \
                Project for the \(holder.act.rawValue) Act since \(Self.timestamp(holder.claimedAt)) \
                (last heartbeat \(Self.timestamp(holder.heartbeatAt)); the lease expires at \
                \(Self.timestamp(holder.expiresAt)) unless heartbeated). No Act was run.
                """
        case .featureNamedForNonAuthoringAct(let act):
            return "A Feature name can only be provided for the author Act, not \(act.rawValue). No Act was run."
        }
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
