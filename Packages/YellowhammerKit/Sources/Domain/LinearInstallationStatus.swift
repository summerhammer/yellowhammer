import Foundation

/// What `yh doctor --check linear --json` says about one Linear Board Connection, read from its rows. The
/// interpretation lives here, not in the app's views, so the Setup wizard's single-installation check and
/// the Settings window's Board connections list read the same rows the same way, and a test can pin it.
public enum LinearInstallationStatus: Equatable, Sendable {
    /// The `authorization` finding passed.
    case connected
    /// The `authorization` finding did not pass; `message` is the doctor's own text.
    case authorizationFailed(message: String)
    /// The `connection` finding failed: no token pair is stored. `message` is the doctor's own text.
    case noTokenPair(message: String)
    /// The rows say nothing about the installation (only `info` rows, or none).
    case unknown

    /// The status in `rows`. With `installation` nil, today's single-installation rule: the first
    /// `authorization` row decides, and no such row means no token pair. With a name, only the rows whose
    /// `installation` equals it count; `info` rows are not faults.
    public static func interpret(_ rows: [DoctorFindingRow], installation: String?) -> LinearInstallationStatus {
        guard let installation else {
            guard let authorization = rows.first(where: { $0.subject == "authorization" }) else {
                return .noTokenPair(message: "")
            }
            return status(of: authorization)
        }
        let own = rows.filter { $0.installation == installation }
        if let authorization = own.first(where: { $0.subject == "authorization" }) {
            return status(of: authorization)
        }
        if let missing = own.first(where: { $0.subject == "connection" && $0.severity == "failure" }) {
            return .noTokenPair(message: missing.message)
        }
        return .unknown
    }

    /// The workspace name any row of `installation` carries, as read live from Linear.
    public static func workspaceName(in rows: [DoctorFindingRow], installation: String) -> String? {
        rows.first { $0.installation == installation && !($0.workspaceName ?? "").isEmpty }?.workspaceName
    }

    /// The name a row shows for an installation: the workspace name when known, else the local name. Never
    /// blank, and never the workspace ID (OQ117).
    public static func label(workspaceName: String?, localName: String) -> String {
        guard let workspaceName, !workspaceName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return localName
        }
        return workspaceName
    }

    /// The text a row shows for this status; nil when the doctor said nothing.
    public var message: String? {
        switch self {
        case .connected: "Connected."
        case .authorizationFailed(let message), .noTokenPair(let message): message.isEmpty ? nil : message
        case .unknown: nil
        }
    }

    private static func status(of authorization: DoctorFindingRow) -> LinearInstallationStatus {
        authorization.severity == "pass" ? .connected : .authorizationFailed(message: authorization.message)
    }
}
