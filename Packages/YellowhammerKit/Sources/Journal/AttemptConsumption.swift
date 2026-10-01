import Foundation

// Split out of Attempt.swift to keep that file under the length limit: ``AttemptHistory/consumption(inEpoch:)``
// is the source, this is what it returns.

/// How one budget epoch's Attempts were spent, read from the Journal's Attempt history alone
/// (``AttemptHistory/consumption(inEpoch:)``). Triage must be able to tell "three Routes couldn't do
/// this" from "my Mac rebooted twice" from ``description`` alone.
public struct AttemptConsumption: Equatable, Sendable {
    /// Every Attempt of the epoch whose ending is not `question`, `cancelled` or `aborted` — an open (unclassified) Attempt
    /// counts too, because the row is written at dispatch, before the ending is known.
    public let consumed: Int
    /// Attempts that ended `hard failure`.
    public let routesFailed: Int
    /// Attempts that ended `rounds-exhausted`.
    public let roundsExhausted: Int
    /// Attempts that ended `Crashed-Unknown`.
    public let crashedUnknown: Int
    /// Attempts that ended `success`.
    public let succeeded: Int
    /// Attempts that ended `question`, `cancelled` or `aborted` — the endings that consume nothing: asking
    /// has no resumable state to protect a budget for, neither does a Card cancelled mid-run, and an
    /// Operator abort is not the Route's failure.
    public let notConsumed: Int

    public init(
        consumed: Int, routesFailed: Int, roundsExhausted: Int, crashedUnknown: Int, succeeded: Int,
        notConsumed: Int
    ) {
        self.consumed = consumed
        self.routesFailed = routesFailed
        self.roundsExhausted = roundsExhausted
        self.crashedUnknown = crashedUnknown
        self.succeeded = succeeded
        self.notConsumed = notConsumed
    }

    /// The Operator-facing account: how many Attempts were consumed and, of those, how many by what —
    /// omitting every part that is zero, so a run with one kind of ending reads as one clause.
    public var description: String {
        var parts: [String] = []
        if routesFailed > 0 {
            parts.append("\(routesFailed) Route\(routesFailed == 1 ? "" : "s") failed")
        }
        if roundsExhausted > 0 {
            parts.append("\(roundsExhausted) round budget exhausted")
        }
        if crashedUnknown > 0 {
            parts.append("\(crashedUnknown) Crashed-Unknown")
        }
        if succeeded > 0 {
            parts.append("\(succeeded) succeeded")
        }
        let attemptWord = consumed == 1 ? "Attempt" : "Attempts"
        guard !parts.isEmpty else {
            return "\(consumed) \(attemptWord) consumed"
        }
        return "\(consumed) \(attemptWord) consumed: \(parts.joined(separator: ", "))"
    }
}
