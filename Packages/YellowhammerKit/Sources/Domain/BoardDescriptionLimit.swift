/// The unit a board counts a description's length in. A board adapter supplies it with its own limit
/// (``BoardDescriptionLimit``), so a description budget is measured the way the board measures.
public enum DescriptionLengthUnit: Equatable, Sendable {
    /// UTF-16 code units: a JavaScript string's `length`. A character outside the Basic Multilingual
    /// Plane (most emoji) counts 2.
    case utf16CodeUnits
    /// Extended grapheme clusters: what a person reads as one character.
    case characters

    /// How many of this unit `text` is long.
    public func length(of text: String) -> Int {
        switch self {
        case .utf16CodeUnits:
            text.utf16.count
        case .characters:
            text.count
        }
    }

    /// The unit's name in the plural, for a message quoting a count.
    public var plural: String {
        switch self {
        case .utf16CodeUnits:
            "UTF-16 code units"
        case .characters:
            "characters"
        }
    }
}

/// The longest description a board accepts, and the unit it counts in. Supplied as a plain value by a
/// board adapter: the Domain and the Engine never hardcode a vendor's number (ADR-001).
public struct BoardDescriptionLimit: Equatable, Sendable {
    public let maximum: Int
    public let unit: DescriptionLengthUnit

    public init(maximum: Int, unit: DescriptionLengthUnit) {
        self.maximum = maximum
        self.unit = unit
    }

    /// The largest description budget a Board Connection may configure: 90% of ``maximum``, rounded down.
    /// The rest is headroom for what the board adds or rewrites around a description.
    public var budgetCeiling: Int {
        maximum / 10 * 9 + maximum % 10 * 9 / 10
    }
}
