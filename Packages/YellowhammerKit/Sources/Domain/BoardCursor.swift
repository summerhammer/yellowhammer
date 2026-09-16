/// Where a paged board read left off, as the board wrote it.
///
/// Opaque for the same reason as ``BoardObjectID``: it is only ever handed back to the board that issued it.
public struct BoardCursor: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension BoardCursor: CustomStringConvertible {
    public var description: String { rawValue }
}
