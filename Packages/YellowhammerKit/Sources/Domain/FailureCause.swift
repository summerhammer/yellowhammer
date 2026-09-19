import CryptoKit
import Foundation

/// What a failed Attempt is reduced to before the Journal counts its Failure-Cause Recurrence
/// (loop-state/record-failure-cause-recurrence, roadmap P8.8). Only structural facts enter it — the
/// stored outcome vocabulary, an exit status, a signal, the Lens that spent the round budget — so the
/// same wall hashes the same on whatever Route met it. Model-authored prose (a reported reason, a
/// result file's error text), the Route and the Round count are deliberately left out: a cause that
/// depended on a model's wording would never recur.
public struct FailureCause: Equatable, Sendable {
    /// The structural facts, `|`-separated: what ``hash`` is taken over.
    public let canonical: String
    /// The Operator-facing name of the cause, as the Card's board projection shows it.
    public let summary: String

    /// `nil` for a success or a question: neither is a failure, so neither has a cause to count.
    /// `lens` is the Lens of the Round that spent the round budget; only `rounds-exhausted` reads it.
    public init?(ending: AttemptEnding, lens: Lens? = nil) {
        let outcome = ending.outcome.rawValue
        let detail: String
        switch ending {
        case .success, .question:
            return nil
        case .hardFailure(.exitStatus(let status)):
            detail = "exit status \(status)"
        case .hardFailure(.reported):
            detail = "reported"
        case .roundsExhausted:
            detail = lens?.rawValue ?? "unknown lens"
        case .crashedUnknown(.resultFile):
            detail = "result file"
        case .crashedUnknown(.terminated):
            detail = "terminated"
        case .crashedUnknown(.signaled(let signal)):
            detail = "signaled \(signal)"
        }
        self.canonical = "\(outcome)|\(detail)"
        self.summary = "\(outcome) (\(detail))"
    }

    /// The failure-cause hash (`failCauseHash`): lowercase hex SHA-256 of ``canonical``.
    public var hash: String {
        SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
