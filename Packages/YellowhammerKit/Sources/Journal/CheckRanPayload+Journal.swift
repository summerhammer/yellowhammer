import Domain
import Foundation

/// The `checkRan` payload's string encoding. The sibling HEADs ride in one optional `sibling_heads` key:
/// records joined by U+001E, each `repository U+001F before U+001F after`, a head being the full SHA, the
/// literal `no held Worktree`, or `unreadable: <reason>`. The lockfile rides in the optional
/// `lockfile_path` and `lockfile_identity` keys (`absent` or the blob object ID). Old rows without the
/// keys decode to `[]` and `.unknown`.
extension CheckRanPayload {
    private static let recordSeparator: Character = "\u{1E}"
    private static let fieldSeparator: Character = "\u{1F}"
    private static let noHeldWorktreeText = "no held Worktree"
    private static let unreadablePrefix = "unreadable: "
    private static let absentText = "absent"

    var journalPayload: [String: String] {
        var dict: [String: String] = [
            "card_id": String(cardID), "issue_id": issueID, "attempt_id": String(attemptID),
            "result": result.rawValue
        ]
        if let exitStatus { dict["exit_status"] = String(exitStatus) }
        if let output { dict["output"] = output }
        if let judgedCommit { dict["judged_commit"] = judgedCommit }
        if let command { dict["command"] = command }
        if !siblings.isEmpty {
            dict["sibling_heads"] = siblings.map { sibling in
                [Self.clean(sibling.repository), Self.text(sibling.before), Self.text(sibling.after)]
                    .joined(separator: String(Self.fieldSeparator))
            }.joined(separator: String(Self.recordSeparator))
        }
        switch lockfile {
        case .unknown: break
        case .absent(let path):
            dict["lockfile_path"] = path
            dict["lockfile_identity"] = Self.absentText
        case .blob(let path, let objectID):
            dict["lockfile_path"] = path
            dict["lockfile_identity"] = objectID
        }
        return dict
    }

    static func decodeSiblings(_ raw: String?) -> [CheckSiblingState] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: recordSeparator, omittingEmptySubsequences: true).compactMap { record in
            let fields = record.split(separator: fieldSeparator, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return CheckSiblingState(
                repository: String(fields[0]), before: head(String(fields[1])), after: head(String(fields[2]))
            )
        }
    }

    static func decodeLockfile(path: String?, identity: String?) -> LockfileIdentity {
        guard let path, let identity else { return .unknown }
        return identity == absentText ? .absent(path: path) : .blob(path: path, objectID: identity)
    }

    private static func text(_ head: SiblingWorktreeHead) -> String {
        switch head {
        case .commit(let sha): clean(sha)
        case .noHeldWorktree: noHeldWorktreeText
        case .unreadable(let reason): unreadablePrefix + clean(reason)
        }
    }

    private static func head(_ text: String) -> SiblingWorktreeHead {
        if text == noHeldWorktreeText { return .noHeldWorktree }
        if text.hasPrefix(unreadablePrefix) {
            return .unreadable(reason: String(text.dropFirst(unreadablePrefix.count)))
        }
        return .commit(text)
    }

    private static func clean(_ text: String) -> String {
        text.filter { $0 != recordSeparator && $0 != fieldSeparator }
    }
}
