/// A per-Card route instruction the Operator writes in the Work Card's description: the value of its one
/// `Card override:` line, a whole Route written as `cli/model/effort` (Decision Gates Ruling, G-17, as
/// amended by the Override Ruling, OQ126; the field replaced the `Override` label group in roadmap P22.7,
/// see ``CardOverrideField``).
///
/// It holds only the value as the Operator spelled it. Resolution matches that text against the
/// Project's Routing Table first and splits it only when nothing matches, so no axis is pinned alone
/// and none is ever filled from a Routing Entry. A Card override wins over Kind, Repo Role and
/// attempt-history exclusion, never over Probe failure, Route Pre-flight or budgets, and under it the
/// entry's fallbacks are not consulted. Only the Operator clears it, by emptying or removing the line.
public struct Override: Hashable, Sendable {
    /// The `Card override:` line's value, spelled as the Operator wrote it.
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
