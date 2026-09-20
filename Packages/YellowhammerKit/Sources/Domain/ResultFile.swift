import Foundation

/// Decodes and validates a result file the CLI wrote against the forced JSON schema
/// (``ResultSchema``). Completion is dual-key — exit 0 AND a non-empty, schema-valid file — so every
/// failure mode here (an empty file, truncated JSON, the wrong pass, an unknown schema version, or a
/// field that breaks its own rule) must be distinguishable, not folded into one generic error.
public enum ResultFile {
    /// Decodes `data` as the result file for `pass`. Never throws a Foundation or `DecodingError`
    /// directly — every failure is a ``ResultFileError`` case naming what went wrong.
    public static func decode(_ data: Data, expecting pass: RunPass) throws(ResultFileError) -> DispatchResult {
        guard !isEmptyOrWhitespace(data) else { throw .empty }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .malformedJSON(error.localizedDescription)
        }

        guard let object = json as? [String: Any] else {
            throw .unknownSchema("top-level JSON value is not an object")
        }
        guard let schema = object["schema"] as? String,
            let found = RunPass.allCases.first(where: { $0.schemaIdentifier == schema })
        else {
            let declared = object["schema"].map(String.init(describing:)) ?? "<missing>"
            throw .unknownSchema(declared)
        }
        guard found == pass else {
            throw .passMismatch(expected: pass, found: found)
        }
        guard let version = object["version"] as? Int else {
            throw .invalid(field: "version", reason: "missing or not an integer")
        }
        guard version == 1 else {
            throw .unsupportedVersion(version)
        }

        return try decodeBody(object, pass: pass)
    }

    private static func decodeBody(_ object: [String: Any], pass: RunPass) throws(ResultFileError) -> DispatchResult {
        switch pass {
        case .architect:
            return .architect(try decodeArchitect(object))
        case .worker:
            return .worker(try decodeWorker(object))
        case .reviewer:
            return .reviewer(try decodeReviewer(object))
        case .selection:
            return .selection(try decodeSelection(object))
        case .breakdown:
            return .breakdown(try decodeBreakdown(object))
        }
    }

    /// Decodes the result file at `url`. A missing or unreadable file throws
    /// ``ResultFileError/unreadable(_:)`` rather than crashing.
    public static func decode(contentsOf url: URL, expecting pass: RunPass) throws -> DispatchResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ResultFileError.unreadable("\(error)")
        }
        return try decode(data, expecting: pass)
    }

    // MARK: - Per-pass field parsing

    private static func decodeArchitect(_ object: [String: Any]) throws(ResultFileError) -> ArchitectResult {
        let outcomeRaw = try string(object, "outcome")
        switch outcomeRaw {
        case "planned":
            let plan = try nonEmptyString(object, "plan")
            let affectedPaths = try stringArray(object, "affected_paths") ?? []
            return ArchitectResult(outcome: .planned(plan: plan, affectedPaths: affectedPaths))
        case "failed":
            let reason = try nonEmptyString(object, "reason")
            return ArchitectResult(outcome: .failed(reason: reason))
        default:
            throw .invalid(field: "outcome", reason: "unknown outcome `\(outcomeRaw)`")
        }
    }

    private static func decodeWorker(_ object: [String: Any]) throws(ResultFileError) -> WorkerResult {
        let outcomeRaw = try string(object, "outcome")
        switch outcomeRaw {
        case "completed":
            let commit = try hexCommit(object, "commit")
            let summary = try nonEmptyString(object, "summary")
            return WorkerResult(outcome: .completed(commit: commit, summary: summary))
        case "question":
            let question = try nonEmptyString(object, "question")
            return WorkerResult(outcome: .question(question))
        case "failed":
            let reason = try nonEmptyString(object, "reason")
            return WorkerResult(outcome: .failed(reason: reason))
        default:
            throw .invalid(field: "outcome", reason: "unknown outcome `\(outcomeRaw)`")
        }
    }

    private static func decodeReviewer(_ object: [String: Any]) throws(ResultFileError) -> ReviewerResult {
        let verdictRaw = try string(object, "verdict")
        let judgedCommit = try hexCommit(object, "judged_commit")
        let summary = try nonEmptyString(object, "summary")
        let requestedChanges = try stringArray(object, "requested_changes") ?? []
        switch verdictRaw {
        case "approved":
            guard requestedChanges.isEmpty else {
                throw .invalid(field: "requested_changes", reason: "must be empty when verdict is `approved`")
            }
            return ReviewerResult(outcome: .approved(judgedCommit: judgedCommit, summary: summary))
        case "changes_requested":
            guard !requestedChanges.isEmpty else {
                throw .invalid(
                    field: "requested_changes",
                    reason: "must be non-empty when verdict is `changes_requested`"
                )
            }
            let outcome = ReviewerOutcome.changesRequested(
                judgedCommit: judgedCommit, summary: summary, requestedChanges: requestedChanges
            )
            return ReviewerResult(outcome: outcome)
        default:
            throw .invalid(field: "verdict", reason: "unknown verdict `\(verdictRaw)`")
        }
    }

    // MARK: - Field helpers

    private static func isEmptyOrWhitespace(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func string(_ object: [String: Any], _ key: String) throws(ResultFileError) -> String {
        guard let value = object[key] as? String else {
            throw .invalid(field: key, reason: "missing or not a string")
        }
        return value
    }

    static func nonEmptyString(_ object: [String: Any], _ key: String) throws(ResultFileError) -> String {
        let value = try string(object, key)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalid(field: key, reason: "must not be empty")
        }
        return value
    }

    static func stringArray(_ object: [String: Any], _ key: String) throws(ResultFileError) -> [String]? {
        guard let raw = object[key] else { return nil }
        guard let array = raw as? [String] else {
            throw .invalid(field: key, reason: "must be an array of strings")
        }
        return array
    }

    private static func hexCommit(_ object: [String: Any], _ key: String) throws(ResultFileError) -> String {
        let value = try string(object, key)
        let isValidSHA = value.count == 40 && value.allSatisfy { "0123456789abcdef".contains($0) }
        guard isValidSHA else {
            throw .invalid(field: key, reason: "must be exactly 40 lowercase hex characters")
        }
        return value
    }
}
