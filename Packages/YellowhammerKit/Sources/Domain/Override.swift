/// A per-Card route instruction the Operator sets on the board: up to three pins, one per axis of the
/// Route, read from the three mutually exclusive label groups `Override CLI`, `Override Model` and
/// `Override Effort` (Decision Gates Ruling, G-17).
///
/// An absent axis is filled from the Card's resolved Routing Entry at resolution. An Override wins
/// over Kind, Repo Role and attempt-history exclusion, never over Probe failure, and under it the
/// entry's fallbacks are not consulted. The Operator sets it; nothing ever clears it.
public struct Override: Hashable, Sendable {
    public var cli: String?
    public var model: String?
    public var effort: String?

    public init(cli: String? = nil, model: String? = nil, effort: String? = nil) {
        self.cli = cli
        self.model = model
        self.effort = effort
    }

    /// No axis pinned: the Card has no Override.
    public static let none = Override()

    /// True when no axis is pinned.
    public var isEmpty: Bool {
        cli == nil && model == nil && effort == nil
    }
}

extension Override: CustomStringConvertible {
    public var description: String {
        "\(cli ?? "-")/\(model ?? "-")/\(effort ?? "-")"
    }
}
