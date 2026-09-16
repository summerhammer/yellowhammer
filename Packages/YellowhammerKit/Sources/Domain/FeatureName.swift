import Foundation

/// A validated name for a Feature the Operator names when forcing authoring.
///
/// Accepts any non-empty text after trimming whitespace and newlines. Stores the trimmed form.
/// Rejects empty or whitespace-only values.
public struct FeatureName: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    /// Fails when the name is empty or contains only whitespace and newlines.
    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }
}

extension FeatureName: CustomStringConvertible {
    public var description: String { rawValue }
}
