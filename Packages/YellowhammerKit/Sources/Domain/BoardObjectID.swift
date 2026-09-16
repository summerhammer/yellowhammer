/// A board's identifier for one of its objects, crossing the Board Port as an opaque value (ADR-001).
///
/// Yellowhammer never parses it: it is stored, compared and handed back to the same board, nothing more.
public struct BoardObjectID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension BoardObjectID: CustomStringConvertible {
    public var description: String { rawValue }
}
