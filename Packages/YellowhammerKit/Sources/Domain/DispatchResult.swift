/// The passes of one dispatch: architect plans, worker executes, reviewer judges — and, for the author
/// Act (roadmap P9.11), selection chooses the next Feature and breakdown drafts its Cards. The last two
/// dispatch under the reserved authoring Kind and are read-only, like architect and reviewer.
public enum RunPass: String, CaseIterable, Sendable, Codable {
    case architect
    case worker
    case reviewer
    case selection
    case breakdown

    /// True for the two author Act passes, which run no Card and no Worktree.
    public var isAuthoring: Bool {
        switch self {
        case .selection, .breakdown: true
        case .architect, .worker, .reviewer: false
        }
    }

    /// The `schema` value every result file for this pass must declare, e.g. `yellowhammer.result.worker`.
    public var schemaIdentifier: String { "yellowhammer.result.\(rawValue)" }
}

/// What the architect pass decided: a plan to hand to the worker, or that it could not produce one.
public enum ArchitectOutcome: Equatable, Sendable {
    case planned(plan: String, affectedPaths: [String])
    case failed(reason: String)
}

/// The architect pass's result-file contents (everything after the envelope's `schema`/`version`).
public struct ArchitectResult: Equatable, Sendable, Codable {
    public let outcome: ArchitectOutcome
    /// What this Card needed that another Card in the Feature has yet to do (graph-execution/
    /// handle-a-block-mid-graph, P8.9): an authoring-invariant violation, reported alongside a `failed`
    /// outcome rather than folded into `reason`, so the engine can tell the two apart without parsing
    /// prose.
    public let authoringInvariantViolation: String?

    public init(outcome: ArchitectOutcome, authoringInvariantViolation: String? = nil) {
        self.outcome = outcome
        self.authoringInvariantViolation = authoringInvariantViolation
    }

    private enum ExtraCodingKeys: String, CodingKey {
        case authoringInvariantViolation = "authoring_invariant_violation"
    }

    public init(from decoder: Decoder) throws {
        self.outcome = try ArchitectOutcome(from: decoder)
        let container = try decoder.container(keyedBy: ExtraCodingKeys.self)
        self.authoringInvariantViolation = try container.decodeIfPresent(
            String.self, forKey: .authoringInvariantViolation
        )
    }

    public func encode(to encoder: Encoder) throws {
        try outcome.encode(to: encoder)
        if let authoringInvariantViolation {
            var container = encoder.container(keyedBy: ExtraCodingKeys.self)
            try container.encode(authoringInvariantViolation, forKey: .authoringInvariantViolation)
        }
    }
}

extension ArchitectOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case outcome
        case plan
        case affectedPaths = "affected_paths"
        case reason
    }

    private enum Kind: String, Codable {
        case planned
        case failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .outcome) {
        case .planned:
            let plan = try container.decode(String.self, forKey: .plan)
            let affectedPaths = try container.decodeIfPresent([String].self, forKey: .affectedPaths) ?? []
            self = .planned(plan: plan, affectedPaths: affectedPaths)
        case .failed:
            self = .failed(reason: try container.decode(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .planned(let plan, let affectedPaths):
            try container.encode(Kind.planned, forKey: .outcome)
            try container.encode(plan, forKey: .plan)
            try container.encode(affectedPaths, forKey: .affectedPaths)
        case .failed(let reason):
            try container.encode(Kind.failed, forKey: .outcome)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// What the worker pass did: completed with a commit, surfaced a question for the Operator (which
/// moves the Card to Waiting on You), or failed outright.
public enum WorkerOutcome: Equatable, Sendable {
    case completed(commit: String, summary: String)
    case question(String)
    case failed(reason: String)
}

/// The worker pass's result-file contents (everything after the envelope's `schema`/`version`).
public struct WorkerResult: Equatable, Sendable, Codable {
    public let outcome: WorkerOutcome
    /// What this Card needed that another Card in the Feature has yet to do (graph-execution/
    /// handle-a-block-mid-graph, P8.9): an authoring-invariant violation, reported alongside a `failed`
    /// outcome rather than folded into `reason`, so the engine can tell the two apart without parsing
    /// prose.
    public let authoringInvariantViolation: String?

    public init(outcome: WorkerOutcome, authoringInvariantViolation: String? = nil) {
        self.outcome = outcome
        self.authoringInvariantViolation = authoringInvariantViolation
    }

    private enum ExtraCodingKeys: String, CodingKey {
        case authoringInvariantViolation = "authoring_invariant_violation"
    }

    public init(from decoder: Decoder) throws {
        self.outcome = try WorkerOutcome(from: decoder)
        let container = try decoder.container(keyedBy: ExtraCodingKeys.self)
        self.authoringInvariantViolation = try container.decodeIfPresent(
            String.self, forKey: .authoringInvariantViolation
        )
    }

    public func encode(to encoder: Encoder) throws {
        try outcome.encode(to: encoder)
        if let authoringInvariantViolation {
            var container = encoder.container(keyedBy: ExtraCodingKeys.self)
            try container.encode(authoringInvariantViolation, forKey: .authoringInvariantViolation)
        }
    }
}

extension WorkerOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case outcome
        case commit
        case summary
        case question
        case reason
    }

    private enum Kind: String, Codable {
        case completed
        case question
        case failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .outcome) {
        case .completed:
            let commit = try container.decode(String.self, forKey: .commit)
            let summary = try container.decode(String.self, forKey: .summary)
            self = .completed(commit: commit, summary: summary)
        case .question:
            self = .question(try container.decode(String.self, forKey: .question))
        case .failed:
            self = .failed(reason: try container.decode(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .completed(let commit, let summary):
            try container.encode(Kind.completed, forKey: .outcome)
            try container.encode(commit, forKey: .commit)
            try container.encode(summary, forKey: .summary)
        case .question(let question):
            try container.encode(Kind.question, forKey: .outcome)
            try container.encode(question, forKey: .question)
        case .failed(let reason):
            try container.encode(Kind.failed, forKey: .outcome)
            try container.encode(reason, forKey: .reason)
        }
    }
}
