import Foundation

/// One row of `yh doctor --json`: the single shared shape the engine encodes and Pulse and the app decode,
/// so the three can never drift. The output is one compact JSON array on the command's last line.
///
/// The optional fields are omitted from the JSON when nil, so a row without them encodes exactly as the
/// four base fields do.
public struct DoctorFindingRow: Codable, Equatable, Sendable {
    public var check: String
    public var subject: String
    /// `"pass"`, `"warning"`, `"failure"` or `"info"`.
    public var severity: String
    public var message: String
    /// The App Installation's local name, when the finding is about one.
    public var installation: String?
    /// The Linear workspace ID the installation belongs to (an opaque vendor ID).
    public var workspace: String?
    /// The workspace's name as read live from Linear.
    public var workspaceName: String?
    /// The ids of the Projects the installation serves.
    public var projects: [String]?
    /// `"authorized"`, `"refused"` or `"unreachable"` (``InstallationAuthorizationState``), only on the
    /// installation rows that judge authorization.
    public var authorization: String?

    public init(
        check: String, subject: String, severity: String, message: String,
        installation: String? = nil, workspace: String? = nil, workspaceName: String? = nil,
        projects: [String]? = nil, authorization: String? = nil
    ) {
        self.check = check
        self.subject = subject
        self.severity = severity
        self.message = message
        self.installation = installation
        self.workspace = workspace
        self.workspaceName = workspaceName
        self.projects = projects
        self.authorization = authorization
    }

    /// The rows in the last non-blank line of `yh doctor --json`'s output, decoded as a JSON array. Nil
    /// when there is no such line or it is not the array.
    public static func decodeLastLine(_ lines: [String]) -> [DoctorFindingRow]? {
        guard let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }
        return try? JSONDecoder().decode([DoctorFindingRow].self, from: Data(last.utf8))
    }

    /// `rows` as one compact JSON array with sorted keys; `"[]"` if encoding fails.
    public static func encodeLine(_ rows: [DoctorFindingRow]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(rows), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}
