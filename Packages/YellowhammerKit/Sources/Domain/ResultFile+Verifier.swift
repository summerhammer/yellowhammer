import Foundation

// The verifier pass (roadmap P10.5), split out of ResultFile.swift to keep it under the file length limit.

extension ResultFile {
    static func decodeVerifier(_ object: [String: Any]) throws(ResultFileError) -> VerifierResult {
        let outcomeRaw = try string(object, "outcome")
        switch outcomeRaw {
        case "reported":
            var seen: Set<String> = []
            let clauses = try verifiedClauses(object, seen: &seen)
            let dropped = try droppedClauses(object, seen: &seen)
            guard !clauses.isEmpty || !dropped.isEmpty else {
                throw .invalid(field: "clauses", reason: "must name at least one clause")
            }
            return VerifierResult(outcome: .reported(clauses: clauses, dropped: dropped))
        case "failed":
            return VerifierResult(outcome: .failed(reason: try nonEmptyString(object, "reason")))
        default:
            throw .invalid(field: "outcome", reason: "unknown outcome `\(outcomeRaw)`")
        }
    }

    /// The `clauses` list. `seen` is shared with ``droppedClauses(_:seen:)`` so that a clause named in
    /// both lists is refused.
    private static func verifiedClauses(
        _ object: [String: Any], seen: inout Set<String>
    ) throws(ResultFileError) -> [VerifiedClause] {
        guard let raw = object["clauses"], !(raw is NSNull) else { return [] }
        guard let items = raw as? [[String: Any]] else {
            throw .invalid(field: "clauses", reason: "must be an array of objects")
        }
        var clauses: [VerifiedClause] = []
        for (index, item) in items.enumerated() {
            let clause = try verifiedClause(item, path: "clauses[\(index)]")
            guard seen.insert("\(clause.issueID)\u{1F}\(clause.cid)").inserted else {
                throw .invalid(
                    field: "clauses[\(index)]", reason: "clause \(clause.issueID)/\(clause.cid) is judged twice"
                )
            }
            clauses.append(clause)
        }
        return clauses
    }

    /// The `dropped` list: each entry names a clause and the one permitted reason.
    private static func droppedClauses(
        _ object: [String: Any], seen: inout Set<String>
    ) throws(ResultFileError) -> [DroppedVerificationClause] {
        guard let rawDropped = object["dropped"], !(rawDropped is NSNull) else { return [] }
        guard let items = rawDropped as? [[String: Any]] else {
            throw .invalid(field: "dropped", reason: "must be an array of objects")
        }
        var dropped: [DroppedVerificationClause] = []
        for (index, item) in items.enumerated() {
            let path = "dropped[\(index)]"
            let reason = try nonEmptyField(item, "reason", path: path)
            guard reason == "asserts landing's own output" else {
                throw .invalid(field: "\(path).reason", reason: "`\(reason)` is not a permitted reason")
            }
            let clause = DroppedVerificationClause(
                cid: try nonEmptyField(item, "cid", path: path),
                issueID: try nonEmptyField(item, "issue_id", path: path),
                reason: reason
            )
            guard seen.insert("\(clause.issueID)\u{1F}\(clause.cid)").inserted else {
                throw .invalid(field: path, reason: "clause \(clause.issueID)/\(clause.cid) appears twice")
            }
            dropped.append(clause)
        }
        return dropped
    }

    private static func verifiedClause(_ item: [String: Any], path: String) throws(ResultFileError) -> VerifiedClause {
        let verdictRaw = try field(item, "verdict", path: path)
        guard let verdict = ClauseVerdict(rawValue: verdictRaw), verdict != .unresolved else {
            throw .invalid(
                field: "\(path).verdict", reason: "must be `met`, `unmet` or `not checked`, not `\(verdictRaw)`"
            )
        }
        return VerifiedClause(
            cid: try nonEmptyField(item, "cid", path: path),
            issueID: try nonEmptyField(item, "issue_id", path: path),
            verdict: verdict,
            whatWasChecked: try nonEmptyField(item, "what_was_checked", path: path),
            interpretation: try nonEmptyField(item, "interpretation", path: path)
        )
    }

    private static func field(_ object: [String: Any], _ key: String, path: String) throws(ResultFileError) -> String {
        guard let value = object[key] as? String else {
            throw .invalid(field: "\(path).\(key)", reason: "missing or not a string")
        }
        return value
    }

    private static func nonEmptyField(
        _ object: [String: Any], _ key: String, path: String
    ) throws(ResultFileError) -> String {
        let value = try field(object, key, path: path)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalid(field: "\(path).\(key)", reason: "must not be empty")
        }
        return value
    }
}
