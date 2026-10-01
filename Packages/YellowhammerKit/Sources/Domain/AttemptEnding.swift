import Foundation

/// How an Attempt ended: "Route exclusion — four endings, three answers"
/// (routing/exclude-tried-routes-on-retry, object-guide Attempt), plus the Operator's `aborted`, a
/// fifth outcome. The object guide's `outcome` is the first four (and `aborted`); `question` is the one ending that is not an outcome: the worker asked, the Card goes
/// Waiting on You, and asking consumes neither a Round nor an Attempt.
public enum AttemptEnding: Equatable, Sendable {
    case success
    case hardFailure(HardFailureCause)
    case roundsExhausted(rounds: Int)
    case crashedUnknown(CrashedUnknownCause)
    case question
    /// The Card was read Cancelled while this Attempt was open (graph-execution/run-a-card, "A Card
    /// cancelled while it is running", P8.9). Like `question`, this is not an outcome: cancelling
    /// consumes no Attempt budget, excludes no Route, and is never a Block Reason source — there is no
    /// resumable state to protect a budget for.
    case cancelled
    /// The Operator aborted this Attempt, directly (Abort Attempt) or through Stop the engine. A fifth
    /// outcome, never Crashed-Unknown: it consumes no Attempt and excludes no Route.
    case aborted
}

/// Why an Attempt hard-failed: attributable to the CLI, either directly or through the pass's
/// dual-key reviewer/Check verdict.
public enum HardFailureCause: Equatable, Sendable {
    /// A non-zero exit status attributable to the CLI (`RunOutcome.failed`). Treated as a route failure.
    case exitStatus(Int32)
    /// The run completed under the dual key and its result reports failure (`WorkerOutcome.failed`,
    /// `ArchitectOutcome.failed`).
    case reported(reason: String)
}

/// The stored vocabulary of `attempt.result`.
public enum AttemptOutcome: String, CaseIterable, Sendable {
    case success
    case hardFailure = "hard failure"
    case roundsExhausted = "rounds-exhausted"
    case crashedUnknown = "Crashed-Unknown"
    case question
    case cancelled
    case aborted
}

extension AttemptEnding {
    /// The stored `attempt.result` vocabulary this ending maps to.
    public var outcome: AttemptOutcome {
        switch self {
        case .success:
            .success
        case .hardFailure:
            .hardFailure
        case .roundsExhausted:
            .roundsExhausted
        case .crashedUnknown:
            .crashedUnknown
        case .question:
            .question
        case .cancelled:
            .cancelled
        case .aborted:
            .aborted
        }
    }

    /// True for a capability failure — hard failure or rounds-exhausted — the only two endings that
    /// exclude the Route (routing/exclude-tried-routes-on-retry). Crashed-Unknown never excludes: "a
    /// dying host is ours, not the model's." A question never excludes, and neither does success, and
    /// neither does a cancellation or an Operator abort.
    public var excludesRoute: Bool {
        switch self {
        case .hardFailure, .roundsExhausted:
            true
        case .success, .crashedUnknown, .question, .cancelled, .aborted:
            false
        }
    }

    /// True for every ending but a question, a cancellation or an Operator abort: asking consumes
    /// neither a Round nor an Attempt, and the Card goes Waiting on You instead; a cancellation leaves
    /// no resumable state to protect a budget for; an abort is the Operator's, not the route's.
    public var consumesAttempt: Bool {
        self != .question && self != .cancelled && self != .aborted
    }

    /// The `route_exclusion.reason` this ending writes, or nil when it excludes nothing.
    public var exclusionReason: String? {
        switch self {
        case .hardFailure:
            "hard failure"
        case .roundsExhausted:
            "rounds-exhausted"
        case .success, .crashedUnknown, .question, .cancelled, .aborted:
            nil
        }
    }

    /// The detail stored in `attempt.classification`.
    public var classification: String {
        switch self {
        case .success:
            "completed"
        case .hardFailure(.exitStatus(let status)):
            "exit status \(status)"
        case .hardFailure(.reported(let reason)):
            "reported: \(reason)"
        case .roundsExhausted(let rounds):
            "\(rounds) rounds"
        case .crashedUnknown(.resultFile(let error)):
            "result file: \(error)"
        case .crashedUnknown(.terminated(let end)):
            "terminated: \(end)"
        case .crashedUnknown(.signaled(let signal)):
            "signaled \(signal)"
        case .crashedUnknown(.reclaimed(let reason)):
            "reclaimed: \(reason)"
        case .crashedUnknown(.engineStopped(let cause)):
            "\(AttemptEnding.engineStoppedClassificationPrefix)\(cause)"
        case .question:
            "asked a question"
        case .cancelled:
            "Card cancelled"
        case .aborted:
            "aborted by the Operator"
        }
    }

    /// The Operator-facing account stored in `attempt.consumed_how`. Triage must be able to tell
    /// "three routes couldn't do this" from "my Mac rebooted twice" from this string alone.
    public var consumedHow: String {
        switch self {
        case .success:
            "consumed"
        case .hardFailure:
            "consumed; route excluded (hard failure)"
        case .roundsExhausted:
            "consumed; route excluded (rounds-exhausted)"
        case .crashedUnknown(.engineStopped):
            "consumed; route not excluded (Crashed-Unknown, stopped by the engine)"
        case .crashedUnknown:
            "consumed; route not excluded (Crashed-Unknown)"
        case .question:
            "not consumed (asked a question)"
        case .cancelled:
            "not consumed (Card cancelled)"
        case .aborted:
            "not consumed; route not excluded (stopped by the Operator)"
        }
    }

    /// The prefix `classification` uses for ``CrashedUnknownCause/engineStopped(cause:)``, so
    /// ``Journal/AttemptHistory/blockReason(inEpoch:)`` can recognize it from the stored string alone,
    /// reading one source rather than re-deriving the wording (OQ92).
    public static let engineStoppedClassificationPrefix = "stopped by the engine: "

    /// Maps a failed run's dual-key classification onto an ending. `nil` for a completed run: its
    /// ending is decided later, by the reviewer's or Check's verdict, not by the run itself.
    public init?(failedRun outcome: RunOutcome) {
        switch outcome {
        case .failed(let exitStatus):
            self = .hardFailure(.exitStatus(exitStatus))
        case .crashedUnknown(let cause):
            self = .crashedUnknown(cause)
        case .completed:
            return nil
        }
    }
}

extension AttemptEnding: CustomStringConvertible {
    public var description: String {
        "\(outcome.rawValue) (\(classification))"
    }
}
