/// The table an Act reads: the machine-wide base merged with one Project's overrides, once, at load.
///
/// Resolution never sees the two halves separately; the merge happens at configuration load (Machine Scope Ruling,
/// routing/overview). A per-Project Routing Entry replaces the base Entry with the same Key outright, fallbacks
/// included; base Entries with no override pass through; override Entries with no base counterpart are added.
public struct RoutingTable: Equatable, Sendable {
    /// One entry per (Kind, Repo Role).
    public var entries: [RoutingEntry]

    /// Initializes a Routing Table from pre-merged entries.
    public init(entries: [RoutingEntry]) {
        self.entries = entries
    }

    /// Merges a base Routing Table with per-Project overrides.
    ///
    /// A per-Project entry replaces the base entry with the same key outright, fallbacks included;
    /// base entries with no override pass through; overrides with no base counterpart are added.
    /// Order is deterministic: base entries in their file order, each replaced in place by its override when one
    /// exists, followed by the override entries that had no base counterpart, in their file order.
    ///
    /// - Parameters:
    ///   - base: The machine-wide base Routing Table, in file order.
    ///   - overrides: The per-Project Routing Table overrides, in file order.
    public init(base: [RoutingEntry], overrides: [RoutingEntry]) {
        // Both inputs are free of duplicate keys: the decoder refuses a second entry for a key.
        let overridesByKey = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key, $0) })
        let baseKeys = Set(base.map(\.key))
        entries = base.map { overridesByKey[$0.key] ?? $0 }
            + overrides.filter { !baseKeys.contains($0.key) }
    }
}
