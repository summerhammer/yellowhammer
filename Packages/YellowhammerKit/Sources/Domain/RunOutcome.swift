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
    /// Yellowhammer ended the run because a macOS permission prompt was attributed to the CLI's own
    /// process tree: nobody answers a prompt during a Night, so the pass could only wait out its
    /// timeout (#555). Same escalation; `detail` names the prompt and the process that raised it.
    case promptBlocked(detail: String, forcedKill: Bool)
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
        case .promptBlocked(let detail, let forcedKill):
            "promptBlocked(\(detail), forcedKill: \(forcedKill))"
        }
    }
}

/// Why an Attempt is Crashed-Unknown: there is no exit code attributable to the CLI.
public enum CrashedUnknownCause: Equatable, Sendable {
    /// Exit 0, but the result file is missing, empty, malformed JSON or declares no recognised schema (the
    /// Codex SIGTERM failure mode). A file that declares a Yellowhammer result schema but breaks its
    /// contract is ``RunOutcome/contractViolation(_:)`` instead.
    case resultFile(ResultFileError)
    /// Yellowhammer ended the run because the engine aborted. Only ``RunEnd/aborted(forcedKill:)`` is ever
    /// stored here: a run ended at the pass timeout is ``RunOutcome/timedOut(after:)``, a hard failure (#507),
    /// and one ended by a permission prompt is ``engineStopped(cause:)`` (#555).
    case terminated(RunEnd)
    /// A signal Yellowhammer did not send ended the process.
    case signaled(Int32)
    /// A later Act reclaimed a dead run's expired Card Lease and found no way to read the real
    /// outcome — no schema-valid result file of the dead run's last pass, and no `failed(exit status)`
    /// step recorded either (loop-state/reclaim-an-expired-lease, P8.10). `String` is a short,
    /// Operator-facing account of what was missing, e.g. "no result file for the worker pass".
    case reclaimed(String)
    /// The engine stopped the run itself, for a cause that is the host's, not the Route's. Two sources:
    /// a later Act reclaimed a run that recorded, via ``CardRunStep/leaseLeftToExpire``, that the engine
    /// stopped it and left its Lease to expire — not a dying host (OQ92); or the engine ended a live pass
    /// because a macOS permission prompt blocked it (``RunEnd/promptBlocked(detail:forcedKill:)``, #555;
    /// see ``permissionPrompt(_:)``). Same Crashed-Unknown classification; `String` is the cause.
    case engineStopped(cause: String)
}

extension CrashedUnknownCause {
    /// How the cause of ``permissionPrompt(_:)`` begins, so a reader of the stored classification can tell
    /// a permission prompt from any other engine stop.
    public static let permissionPromptCausePrefix = "a macOS permission prompt blocked the pass: "

    /// The engine stop for a pass that a macOS permission prompt blocked (#555). `detail` names the prompt.
    public static func permissionPrompt(_ detail: String) -> CrashedUnknownCause {
        .engineStopped(cause: permissionPromptCausePrefix + detail)
    }

    /// True for the engine stop ``permissionPrompt(_:)`` builds.
    public var isPermissionPrompt: Bool {
        guard case .engineStopped(let cause) = self else { return false }
        return cause.hasPrefix(Self.permissionPromptCausePrefix)
    }
}

/// The dual-key completion verdict of one CLI run: an Attempt completes only with exit status
/// strictly 0 AND a non-empty, schema-valid result file (glossary: Crashed-Unknown).
public enum RunOutcome: Equatable, Sendable {
    /// Exit 0 AND a non-empty, schema-valid result file: the only way an Attempt completes.
    case completed(DispatchResult)
    /// Consumes the Attempt; excludes no route.
    case crashedUnknown(CrashedUnknownCause)
    /// Exit 0, and a result file that declares a Yellowhammer result schema but breaks its contract
    /// (``ResultFileError/isContractViolation``): the CLI answered, so the cause is attributable to the
    /// Route. A hard failure — consumes the Attempt and excludes the route (#445).
    case contractViolation(ResultFileError)
    /// A non-zero exit status attributable to the CLI, after the adapter has ruled out a recognized
    /// usage-limit refusal. A result file, if any, is NOT read: exit 0 is one of the two keys.
    case failed(exitStatus: Int32)
    /// The CLI refused the pass because its account's usage limit was reached. The reset text is
    /// an opaque hint, not a timestamp: the engine owns backoff and Attempt accounting (#547).
    case usageLimited(resetHint: String?)
    /// Yellowhammer ended the run because the Project's pass timeout elapsed (`[limits] pass_timeout_minutes`).
    /// The CLI did not get to answer, so no result file is read. The engine's own decision, not an unknown
    /// crash: a hard failure that consumes the Attempt and excludes the Route (#507).
    case timedOut(after: Duration)
}

extension RunOutcome: CustomStringConvertible {
    public var description: String {
        switch self {
        case .completed(let result):
            "completed(\(result))"
        case .crashedUnknown(let cause):
            "crashedUnknown(\(cause))"
        case .contractViolation(let error):
            "contractViolation(\(error))"
        case .failed(let exitStatus):
            "failed(exitStatus: \(exitStatus))"
        case .usageLimited(let resetHint):
            "usageLimited(\(resetHint ?? "reset time unavailable"))"
        case .timedOut(let after):
            "timedOut(after: \(after))"
        }
    }
}

extension RunOutcome {
    /// Applies the dual-key contract after adapter-specific usage-limit translation. Reads the file
    /// only when `end` is `.exited(status: 0)`; a non-zero exit never consults the result file.
    public static func classify(end: RunEnd, resultFileAt url: URL, pass: RunPass) -> RunOutcome {
        guard case .exited(let status) = end, status == 0 else {
            return classify(nonZeroOrUnexited: end)
        }
        do {
            let result = try ResultFile.decode(contentsOf: url, expecting: pass)
            return .completed(result)
        } catch let error as ResultFileError {
            return classify(resultFileError: error)
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
            return classify(resultFileError: error)
        }
    }

    /// A result file that parsed and declared a Yellowhammer schema but broke its contract is the CLI
    /// answering (a hard failure); one that never did is Crashed-Unknown.
    private static func classify(resultFileError error: ResultFileError) -> RunOutcome {
        error.isContractViolation ? .contractViolation(error) : .crashedUnknown(.resultFile(error))
    }

    /// Shared for every `end` other than a clean exit(0): a non-zero exit is attributable to the
    /// CLI, a timeout is the engine's own hard-failure decision (#507), an abort or a foreign signal
    /// is Crashed-Unknown by construction, and a permission prompt is an engine stop — the host's
    /// fault, not the Route's (#555).
    private static func classify(nonZeroOrUnexited end: RunEnd) -> RunOutcome {
        switch end {
        case .exited(let status):
            .failed(exitStatus: status)
        case .signaled(let signal):
            .crashedUnknown(.signaled(signal))
        case .timedOut(let after, _):
            .timedOut(after: after)
        case .aborted:
            .crashedUnknown(.terminated(end))
        case .promptBlocked(let detail, _):
            .crashedUnknown(.permissionPrompt(detail))
        }
    }
}

extension Duration {
    /// The whole minutes in this duration, rounded down: how a pass timeout is named to the Operator.
    public var wholeMinutes: Int {
        Int(components.seconds / 60)
    }
}
