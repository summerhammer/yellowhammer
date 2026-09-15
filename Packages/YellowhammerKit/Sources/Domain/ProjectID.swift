/// A Project's identifier. It names the Project's configuration file and Journal and its LaunchAgent labels.
///
/// Accepts only ASCII `[A-Za-z0-9_-]+`, because it becomes part of file names and labels.
public struct ProjectID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    /// Fails when the identifier is empty or contains anything outside ASCII `[A-Za-z0-9_-]`.
    public init?(rawValue: String) {
        let valid = !rawValue.isEmpty && rawValue.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", "-": true
            default: false
            }
        }
        guard valid else { return nil }
        self.rawValue = rawValue
    }
}

extension ProjectID: CustomStringConvertible {
    public var description: String { rawValue }
}
