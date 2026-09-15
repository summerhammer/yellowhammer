import Domain
import Foundation
import Journal

/// One Act's work for one Project, then exit.
///
/// An invocation is handed exactly one Project's Journal and holds no other: the Engine never opens
/// a Journal (module boundary rule MB5), so nothing in it can name a sibling Project's. Two Acts of
/// the same Project must not run at once, so the invocation claims the Project's Act-scoped lease
/// before doing anything and stands down, out loud, when another run holds it.
public struct EngineInvocation: Sendable {
    public let act: Act
    public let mode: NightMode
    public let runID: RunID
    public let leasePolicy: LeasePolicy
    private let journal: JournalStore

    public init(
        act: Act,
        mode: NightMode,
        journal: JournalStore,
        runID: RunID = RunID(),
        leasePolicy: LeasePolicy = .ruled
    ) {
        self.act = act
        self.mode = mode
        self.journal = journal
        self.runID = runID
        self.leasePolicy = leasePolicy
    }

    /// The Project this invocation is scoped to: the one whose Journal it was given.
    public var projectID: ProjectID { journal.projectID }

    public func run() async throws {
        switch try journal.claimActLease(act: act, runID: runID, mode: mode, policy: leasePolicy) {
        case .held(let holder):
            throw EngineInvocationError.actLeaseHeld(act: act, projectID: projectID, by: holder)
        case .claimed:
            break
        }
        do {
            try await perform()
        } catch {
            // The Act's failure is the error worth reporting. If the release fails too, the lease
            // frees by its TTL, exactly as it would after a crash.
            _ = try? journal.releaseActLease(runID: runID)
            throw error
        }
        try journal.releaseActLease(runID: runID)
    }

    /// The Act's work, under the lease. Nothing yet: the Acts arrive in later phases.
    private func perform() async throws {
        throw EngineInvocationError.notImplemented(act)
    }
}

public enum EngineInvocationError: Error, Sendable, Equatable {
    case notImplemented(Act)
    /// Another run of the same Project holds its Act-scoped lease. This Act stood down and ran nothing.
    case actLeaseHeld(act: Act, projectID: ProjectID, by: ActLease)
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
        }
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
