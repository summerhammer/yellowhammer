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

/// Encodes as its raw string, and refuses to decode an invalid one. The app scopes each window to a
/// Project by this value, and SwiftUI encodes it to restore windows.
extension ProjectID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let id = ProjectID(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid Project id: \(rawValue)"
            )
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
