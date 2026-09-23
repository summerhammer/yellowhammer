import Domain
import Foundation

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
