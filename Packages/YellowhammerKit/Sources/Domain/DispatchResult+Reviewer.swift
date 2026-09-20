/// What the reviewer pass judged: approved, or changes requested against specific points.
public enum ReviewerOutcome: Equatable, Sendable {
    case approved(judgedCommit: String, summary: String)
    case changesRequested(judgedCommit: String, summary: String, requestedChanges: [String])
}

/// The reviewer pass's result-file contents (everything after the envelope's `schema`/`version`).
/// Unlike the other two passes, its discriminator key is `verdict`, not `outcome`.
public struct ReviewerResult: Equatable, Sendable, Codable {
    public let outcome: ReviewerOutcome

    public init(outcome: ReviewerOutcome) {
        self.outcome = outcome
    }

    public init(from decoder: Decoder) throws {
        self.outcome = try ReviewerOutcome(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try outcome.encode(to: encoder)
    }
}

extension ReviewerOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case verdict
        case judgedCommit = "judged_commit"
        case summary
        case requestedChanges = "requested_changes"
    }

    private enum Kind: String, Codable {
        case approved
        case changesRequested = "changes_requested"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let judgedCommit = try container.decode(String.self, forKey: .judgedCommit)
        let summary = try container.decode(String.self, forKey: .summary)
        switch try container.decode(Kind.self, forKey: .verdict) {
        case .approved:
            self = .approved(judgedCommit: judgedCommit, summary: summary)
        case .changesRequested:
            let requestedChanges = try container.decodeIfPresent([String].self, forKey: .requestedChanges) ?? []
            self = .changesRequested(judgedCommit: judgedCommit, summary: summary, requestedChanges: requestedChanges)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .approved(let judgedCommit, let summary):
            try container.encode(Kind.approved, forKey: .verdict)
            try container.encode(judgedCommit, forKey: .judgedCommit)
            try container.encode(summary, forKey: .summary)
        case .changesRequested(let judgedCommit, let summary, let requestedChanges):
            try container.encode(Kind.changesRequested, forKey: .verdict)
            try container.encode(judgedCommit, forKey: .judgedCommit)
            try container.encode(summary, forKey: .summary)
            try container.encode(requestedChanges, forKey: .requestedChanges)
        }
    }
}

/// A decoded, pass-tagged result file: the outcome of one architect, worker, reviewer, selection or
/// breakdown run.
public enum DispatchResult: Equatable, Sendable {
    case architect(ArchitectResult)
    case worker(WorkerResult)
    case reviewer(ReviewerResult)
    case selection(SelectionResult)
    case breakdown(BreakdownResult)

    public var pass: RunPass {
        switch self {
        case .architect: .architect
        case .worker: .worker
        case .reviewer: .reviewer
        case .selection: .selection
        case .breakdown: .breakdown
        }
    }
}

/// Why a result file failed to decode or validate.
public enum ResultFileError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Zero bytes, or whitespace only: the dual-key completion check never sees a written file.
    case empty
    /// The bytes present are not parsable JSON.
    case malformedJSON(String)
    /// The top-level value was not an object, or its `schema` field was missing or not recognized.
    case unknownSchema(String)
    /// The file's `schema` names a different pass than the one being decoded.
    case passMismatch(expected: RunPass, found: RunPass)
    /// `version` was present but not the only known version, `1`.
    case unsupportedVersion(Int)
    /// A field broke one of the schema's rules: missing, wrong type, empty, or a malformed shape (e.g. a SHA).
    case invalid(field: String, reason: String)
    /// The file could not be read from disk at all (missing, unreadable).
    case unreadable(String)

    public var description: String {
        switch self {
        case .empty:
            "result file is empty or whitespace-only"
        case .malformedJSON(let detail):
            "result file is not valid JSON: \(detail)"
        case .unknownSchema(let detail):
            "result file declares an unknown or missing schema: \(detail)"
        case .passMismatch(let expected, let found):
            "result file declares pass `\(found.rawValue)`, expected `\(expected.rawValue)`"
        case .unsupportedVersion(let version):
            "result file declares unsupported schema version \(version)"
        case .invalid(let field, let reason):
            "field `\(field)` is invalid: \(reason)"
        case .unreadable(let detail):
            "result file could not be read: \(detail)"
        }
    }
}
