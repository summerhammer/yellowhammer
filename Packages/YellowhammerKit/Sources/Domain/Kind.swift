/// A dotted classification of a Card's work, such as `impl.boilerplate`.
///
/// `*` is the root Kind, ``Kind/any``, and has no segments.
public struct Kind: Hashable, Sendable {
    public static let any = Kind(segments: [])

    public let segments: [String]

    private init(segments: [String]) {
        self.segments = segments
    }

    /// Accepts `*`, or dot-separated segments that are non-empty and contain neither whitespace nor `*`.
    public init?(_ string: String) {
        if string == "*" {
            self = .any
            return
        }
        let segments = string.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let valid = segments.allSatisfy { segment in
            !segment.isEmpty && !segment.contains("*") && !segment.contains(where: \.isWhitespace)
        }
        guard valid else { return nil }
        self.init(segments: segments)
    }
}

extension Kind: CustomStringConvertible {
    public var description: String {
        segments.isEmpty ? "*" : segments.joined(separator: ".")
    }
}
