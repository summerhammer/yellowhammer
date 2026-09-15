import Foundation

/// Identifies one engine run: the `runId` a Lease records so that a later run can tell whether the
/// holder is itself, a sibling that is still alive, or a dead run whose Lease has expired.
public struct RunID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    /// A fresh identifier for a run that is starting now.
    public init() {
        rawValue = UUID().uuidString.lowercased()
    }

    /// Fails when the identifier is empty.
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}

extension RunID: CustomStringConvertible {
    public var description: String { rawValue }
}
