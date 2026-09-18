import Foundation

/// One pass of a dispatch, handed across the Dispatch seam: everything an agent CLI run needs, with no
/// vendor type in it. A Route's `cli` is a free string here; the implementation resolves it.
public struct AgentDispatchRequest: Equatable, Sendable {
    public let runID: RunID
    /// The Card's board issue id: names the run directory an implementation keeps, beside the Journal.
    public let issueID: String
    public let attemptID: Int64
    public let route: Route
    public let pass: RunPass
    /// The composed instruction. Its `resultFilePath` is the one the implementation stamps, because the
    /// implementation owns the run directory the result file lives in.
    public let instruction: Instruction
    public let worktreePath: String
    /// An opaque session string a CLI handed back for an earlier pass on the same worker, so a Round
    /// resumes it. Yellowhammer never parses it.
    public let resumeSession: String?
    /// Directories the CLI must be able to write beyond the Worktree, such as a linked Worktree's git
    /// common dir.
    public let additionalWritableDirectories: [String]

    public init(
        runID: RunID,
        issueID: String,
        attemptID: Int64,
        route: Route,
        pass: RunPass,
        instruction: Instruction,
        worktreePath: String,
        resumeSession: String? = nil,
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
        self.additionalWritableDirectories = additionalWritableDirectories
    }
}

/// What one dispatched pass yielded: the dual-key verdict and the opaque session to resume next, if the
/// CLI offered one.
public struct AgentDispatchReport: Equatable, Sendable {
    public let outcome: RunOutcome
    public let session: String?

    public init(outcome: RunOutcome, session: String? = nil) {
        self.outcome = outcome
        self.session = session
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
