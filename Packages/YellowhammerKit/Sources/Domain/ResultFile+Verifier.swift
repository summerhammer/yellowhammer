import Foundation

// The verifier pass (roadmap P10.5), split out of ResultFile.swift to keep it under the file length limit.

extension ResultFile {
    static func decodeVerifier(_ object: [String: Any]) throws(ResultFileError) -> VerifierResult {
        let outcomeRaw = try string(object, "outcome")
        switch outcomeRaw {
        case "reported":
            guard let raw = object["clauses"] else {
                throw .invalid(field: "clauses", reason: "missing or not an array of objects")
            }
            guard let items = raw as? [[String: Any]] else {
                throw .invalid(field: "clauses", reason: "must be an array of objects")
            }
            guard !items.isEmpty else {
                throw .invalid(field: "clauses", reason: "must name at least one clause")
            }
            var seen: Set<String> = []
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
            return VerifierResult(outcome: .reported(clauses: clauses))
        case "failed":
            return VerifierResult(outcome: .failed(reason: try nonEmptyString(object, "reason")))
        default:
            throw .invalid(field: "outcome", reason: "unknown outcome `\(outcomeRaw)`")
        }
    }

    private static func verifiedClause(_ item: [String: Any], path: String) throws(ResultFileError) -> VerifiedClause {
        let verdictRaw = try field(item, "verdict", path: path)
        guard let verdict = ClauseVerdict(rawValue: verdictRaw), verdict != .unresolved else {
            throw .invalid(field: "\(path).verdict", reason: "must be `met` or `unmet`, not `\(verdictRaw)`")
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
