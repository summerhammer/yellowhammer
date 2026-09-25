import Foundation

/// One pass of a dispatch, handed across the Dispatch seam: everything an agent CLI run needs, with no
/// vendor type in it. A Route's `cli` is a free string here; the implementation resolves it.
public struct AgentDispatchRequest: Equatable, Sendable {
    public let runID: RunID
    /// The Card's board issue id: names the run directory an implementation keeps, beside the Journal.
    /// For an authoring request it is the fixed name `authoring`: the author Act has no Card.
    public let issueID: String
    /// For an authoring request, the 1-based ordinal of the candidate Route tried in this Act.
    public let attemptID: Int64
    public let route: Route
    public let pass: RunPass
    /// The composed instruction. Its `resultFilePath` is the one the implementation stamps, because the
    /// implementation owns the run directory the result file lives in.
    public let instruction: AgentInstruction
    /// The directory the CLI runs in. For an authoring request (roadmap P9.11) it is the specification
    /// source's local path, and `issueID` is the fixed run-directory name `authoring`.
    public let worktreePath: String
    /// An opaque session string a CLI handed back for an earlier pass on the same worker, so a Round
    /// resumes it. Yellowhammer never parses it.
    public let resumeSession: String?
    /// Extra directories the CLI must be able to read beyond the Worktree (e.g. working repos during
    /// authoring).
    public let additionalReadableDirectories: [String]
    /// Directories the CLI must be able to write beyond the Worktree, such as a linked Worktree's git
    /// common dir.
    public let additionalWritableDirectories: [String]

    public init(
        runID: RunID,
        issueID: String,
        attemptID: Int64,
        route: Route,
        pass: RunPass,
        instruction: AgentInstruction,
        worktreePath: String,
        resumeSession: String? = nil,
        additionalReadableDirectories: [String] = [],
        additionalWritableDirectories: [String] = []
    ) {
        self.runID = runID
        self.issueID = issueID
        self.attemptID = attemptID
        self.route = route
        self.pass = pass
        self.instruction = instruction
        self.worktreePath = worktreePath
        self.resumeSession = resumeSession
        self.additionalReadableDirectories = additionalReadableDirectories
        self.additionalWritableDirectories = additionalWritableDirectories
    }
}

/// Where one dispatched pass's answer came from: an agent CLI process actually spawned, or a
/// rehearsal Night's fixture answering in its place (system-overview, Environment Differences —
/// a rehearsal Night never dispatches an agent CLI).
public enum AgentDispatchOrigin: Equatable, Sendable {
    case agentCLIProcess
    case rehearsalFixture(String)
}

/// What one dispatched pass yielded: the dual-key verdict and the opaque session to resume next, if the
/// CLI offered one.
public struct AgentDispatchReport: Equatable, Sendable {
    public let outcome: RunOutcome
    public let session: String?
    /// Conservative default: any report that doesn't say otherwise is taken to have spawned an agent
    /// CLI process, so existing fakes that construct a report need no change.
    public let origin: AgentDispatchOrigin
    /// Background tool processes still running after a NORMAL exit, swept and reported by the
    /// implementation (Normal-Exit Sweep Ruling). Defaulted so existing call sites and fakes compile
    /// unchanged.
    public let leftovers: [LeftoverProcess]
    /// The running snapshot this run's process lifecycle captured (Normal-Exit Sweep Ruling), for
    /// the attributed Worktree fence to consume. `nil` when no agent CLI run's snapshot is
    /// available — a fake, or a rehearsal fixture answering in place of a real run.
    public let snapshot: RunningSnapshot?

    public init(
        outcome: RunOutcome, session: String? = nil, origin: AgentDispatchOrigin = .agentCLIProcess,
        leftovers: [LeftoverProcess] = [], snapshot: RunningSnapshot? = nil
    ) {
        self.outcome = outcome
        self.session = session
        self.origin = origin
        self.leftovers = leftovers
        self.snapshot = snapshot
    }
}

/// The route cannot be run at all on this machine: no adapter for its CLI, or no executable to spawn.
/// A failure of the Route for that Attempt, not a fault of the engine.
public struct AgentDispatchRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// The Dispatch seam the Engine owns (ADR-001): how a Card's passes reach an agent CLI. The Port is named
/// `AgentDispatch` because Apple owns the module name `Dispatch`. An implementation translates and never
/// decides; a refusal it cannot avoid is thrown as ``AgentDispatchRefusal``, and any other thrown error is
/// an engine fault.
public protocol AgentDispatch: Sendable {
    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport
}

extension Instruction {
    /// This instruction with its result file path replaced.
    public func withResultFilePath(_ path: String) -> Instruction {
        Instruction(
            pass: pass, card: card, brief: brief, definitionOfDone: definitionOfDone, repository: repository,
            route: route, payloads: payloads, resultFilePath: path
        )
    }
}
