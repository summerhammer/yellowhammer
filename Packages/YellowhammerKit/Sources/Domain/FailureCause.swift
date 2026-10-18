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

    /// `nil` for a success, a question, a cancellation or an Operator abort: none is a failure, so neither has a cause to count.
    /// `lens` is the Lens of the Round that spent the round budget; only `rounds-exhausted` reads it.
    public init?(ending: AttemptEnding, lens: Lens? = nil) {
        let outcome = ending.outcome.rawValue
        let detail: String
        switch ending {
        case .success, .question, .cancelled, .aborted, .usageLimited:
            return nil
        case .hardFailure(.exitStatus(let status)):
            detail = "exit status \(status)"
        case .hardFailure(.reported):
            detail = "reported"
        case .hardFailure(.contractViolation(let error)):
            detail = "contract violation: \(Self.violationKind(error))"
        case .hardFailure(.timedOut):
            // Without the duration, so changing the configured limit does not change the recurrence hash.
            detail = "timed out"
        case .roundsExhausted:
            detail = lens?.rawValue ?? "unknown lens"
        case .crashedUnknown(let cause):
            detail = Self.detail(of: cause)
        }
        self.canonical = "\(outcome)|\(detail)"
        self.summary = "\(outcome) (\(detail))"
    }

    private static func detail(of cause: CrashedUnknownCause) -> String {
        switch cause {
        case .resultFile:
            "result file"
        case .terminated:
            "terminated"
        case .signaled(let signal):
            "signaled \(signal)"
        case .engineStopped where cause.isPermissionPrompt:
            // Without the prompt's detail (a pid), so the same prompt recurring hashes the same (#555).
            "permission prompt"
        case .reclaimed, .engineStopped:
            // Classification is unchanged by OQ92: an engine stop counts as the same structural cause as
            // any other reclaimed Crashed-Unknown, so recurrence still counts across the two.
            "reclaimed"
        }
    }

    /// The structural kind of a contract violation, taken from the error case alone: the field name is
    /// ours, but the reason, the versions and the passes can carry model-authored text, so they stay out.
    private static func violationKind(_ error: ResultFileError) -> String {
        switch error {
        case .completedWithoutCommit:
            "completed without a commit"
        case .passMismatch:
            "pass mismatch"
        case .unsupportedVersion:
            "unsupported version"
        case .invalid(let field, _):
            "invalid \(field)"
        case .empty, .malformedJSON, .unknownSchema, .unreadable:
            // Not contract violations (`ResultFileError.isContractViolation`); never reached.
            "result file"
        }
    }

    /// The failure-cause hash (`failCauseHash`): lowercase hex SHA-256 of ``canonical``.
    public var hash: String {
        SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
