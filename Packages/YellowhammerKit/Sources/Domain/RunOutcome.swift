import Foundation

/// How one agent CLI process ended, as the process lifecycle observed it.
public enum RunEnd: Equatable, Sendable {
    /// The CLI exited on its own with `status`. Non-zero is an exit code attributable to the CLI.
    case exited(status: Int32)
    /// The CLI was ended by a signal Yellowhammer did not send (e.g. the kernel or the Operator).
    case signaled(Int32)
    /// Yellowhammer ended the run because `timeout` elapsed: SIGTERM to the group, the grace
    /// window, then SIGKILL if `forcedKill`.
    case timedOut(after: Duration, forcedKill: Bool)
    /// Yellowhammer ended the run because the engine aborted (Task cancellation). Same escalation;
    /// `forcedKill` says whether SIGKILL was needed.
    case aborted(forcedKill: Bool)
}

extension RunEnd: CustomStringConvertible {
    public var description: String {
        switch self {
        case .exited(let status):
            "exited(\(status))"
        case .signaled(let signal):
            "signaled(\(signal))"
        case .timedOut(let after, let forcedKill):
            "timedOut(after: \(after), forcedKill: \(forcedKill))"
        case .aborted(let forcedKill):
            "aborted(forcedKill: \(forcedKill))"
        }
    }
}

/// Why an Attempt is Crashed-Unknown: there is no exit code attributable to the CLI.
public enum CrashedUnknownCause: Equatable, Sendable {
    /// Exit 0, but the result file is missing, empty or schema-invalid (the Codex SIGTERM failure mode).
    case resultFile(ResultFileError)
    /// Yellowhammer ended the run (timeout or abort). Only ``RunEnd/timedOut(after:forcedKill:)`` or
    /// ``RunEnd/aborted(forcedKill:)`` are ever stored here.
    case terminated(RunEnd)
    /// A signal Yellowhammer did not send ended the process.
    case signaled(Int32)
    /// A later Act reclaimed a dead run's expired Card Lease and found no way to read the real
    /// outcome — no schema-valid result file of the dead run's last pass, and no `failed(exit status)`
    /// step recorded either (loop-state/reclaim-an-expired-lease, P8.10). `String` is a short,
    /// Operator-facing account of what was missing, e.g. "no result file for the worker pass".
    case reclaimed(String)
}

/// The dual-key completion verdict of one CLI run: an Attempt completes only with exit status
/// strictly 0 AND a non-empty, schema-valid result file (glossary: Crashed-Unknown).
public enum RunOutcome: Equatable, Sendable {
    /// Exit 0 AND a non-empty, schema-valid result file: the only way an Attempt completes.
    case completed(DispatchResult)
    /// Consumes the Attempt; excludes no route.
    case crashedUnknown(CrashedUnknownCause)
    /// A non-zero exit status attributable to the CLI, recorded for route-failure classification. A
    /// result file, if any, is NOT read: exit 0 is one of the two keys.
    case failed(exitStatus: Int32)
}

extension RunOutcome: CustomStringConvertible {
    public var description: String {
        switch self {
        case .completed(let result):
            "completed(\(result))"
        case .crashedUnknown(let cause):
            "crashedUnknown(\(cause))"
        case .failed(let exitStatus):
            "failed(exitStatus: \(exitStatus))"
        }
    }
}

extension RunOutcome {
    /// Applies the dual-key contract. Reads the file only when `end` is `.exited(status: 0)` — a
    /// non-zero exit is already the answer, and the file is never consulted.
    public static func classify(end: RunEnd, resultFileAt url: URL, pass: RunPass) -> RunOutcome {
        guard case .exited(let status) = end, status == 0 else {
            return classify(nonZeroOrUnexited: end)
        }
        do {
            let result = try ResultFile.decode(contentsOf: url, expecting: pass)
            return .completed(result)
        } catch let error as ResultFileError {
            return .crashedUnknown(.resultFile(error))
        } catch {
            return .crashedUnknown(.resultFile(.unreadable("\(error)")))
        }
    }

    /// Same contract, over already-read bytes (`nil` standing in for a missing file).
    public static func classify(end: RunEnd, resultFile data: Data?, pass: RunPass) -> RunOutcome {
        guard case .exited(let status) = end, status == 0 else {
            return classify(nonZeroOrUnexited: end)
        }
        guard let data else {
            return .crashedUnknown(.resultFile(.unreadable("result file not found")))
        }
        do {
            let result = try ResultFile.decode(data, expecting: pass)
            return .completed(result)
        } catch {
            return .crashedUnknown(.resultFile(error))
        }
    }

    /// Shared for every `end` other than a clean exit(0): a non-zero exit is attributable to the
    /// CLI, and every other ending is Crashed-Unknown by construction.
    private static func classify(nonZeroOrUnexited end: RunEnd) -> RunOutcome {
        switch end {
        case .exited(let status):
            .failed(exitStatus: status)
        case .signaled(let signal):
            .crashedUnknown(.signaled(signal))
        case .timedOut, .aborted:
            .crashedUnknown(.terminated(end))
        }
    }
}
