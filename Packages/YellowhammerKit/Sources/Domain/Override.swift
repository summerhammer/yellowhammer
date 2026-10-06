/// A per-Card route instruction the Operator sets on the board: one whole Route, read from the one
/// mutually exclusive `Override` label group whose labels are Routes written as `cli/model/effort`
/// (Decision Gates Ruling, G-17, as amended by the Override Ruling, OQ126).
///
/// It holds only the label text as the board spells it. Resolution matches that text against the
/// Project's Routing Table first and splits it only when nothing matches, so no axis is pinned alone
/// and none is ever filled from a Routing Entry. An Override wins over Kind, Repo Role and
/// attempt-history exclusion, never over Probe failure, and under it the entry's fallbacks are not
/// consulted. The Operator sets it; nothing ever clears it.
public struct Override: Hashable, Sendable {
    /// The `Override` group's child label on the Card, spelled as the board spells it.
    public let label: String

    public init(label: String) {
        self.label = label
    }
}

extension Override: CustomStringConvertible {
    public var description: String {
        label
    }
}
