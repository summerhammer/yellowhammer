import Domain
import Foundation

extension BoardProvisioner {
    /// The one mutually exclusive Override label group, whose labels are whole Routes written as
    /// `cli/model/effort` (G-17, as amended by the Override Ruling, OQ126). It replaces the per-axis
    /// groups `Override CLI`, `Override Model` and `Override Effort`.
    static let overrideGroup = "Override"
}

extension RoutingTable {
    /// Every Route the table names, primaries and fallbacks, in table order and each once.
    var allRoutes: [Route] {
        var seen: Set<Route> = []
        return entries.flatMap { [$0.route] + $0.fallbacks }.filter { seen.insert($0).inserted }
    }
}

/// The labels the `Override` group is provisioned with: every distinct Route of the merged Routing
/// Table, primaries and fallbacks, as its `cli/model/effort` text, sorted (OQ126). Two different
/// Routes whose texts are equal ignoring case cannot both be labels — the board matches label names
/// case-insensitively, and so does resolution — so both are refused, naming their Routing Entries.
public struct OverrideLabelValues: Equatable, Sendable {
    /// The label texts to provision, sorted.
    public var labels: [String]
    /// Each label text to the Routing Entries that name its Route, as an Operator-facing account.
    public var entries: [String: String]
    /// Each refused label text to why it is refused, naming the Routing Entries.
    public var refusals: [String: String]

    public init(table: RoutingTable) {
        var namedBy: [Route: [RoutingEntry.Key]] = [:]
        for entry in table.entries {
            for route in [entry.route] + entry.fallbacks where namedBy[route]?.contains(entry.key) != true {
                namedBy[route, default: []].append(entry.key)
            }
        }
        let byText = Dictionary(grouping: table.allRoutes) { $0.description.lowercased() }
        var labels: [String] = []
        var entries: [String: String] = [:]
        var refusals: [String: String] = [:]
        for routes in byText.values {
            let accounts = routes.flatMap { namedBy[$0] ?? [] }.map(\.account)
            if routes.count > 1 {
                let texts = routes.map { "`\($0)`" }.joined(separator: " and ")
                for route in routes {
                    refusals[route.description] =
                        "the Routes \(texts) render to the same label; Routing Entries "
                            + accounts.joined(separator: ", ")
                }
            } else if let route = routes.first {
                labels.append(route.description)
                entries[route.description] = accounts.joined(separator: ", ")
            }
        }
        self.labels = labels.sorted()
        self.entries = entries
        self.refusals = refusals
    }
}

/// The `Override` label group as a team exposes it, resolved from the labels the board reports: its
/// children, by name. A team without the group carries no Override — not an error, because a Card
/// carries an Override only when the Operator set one.
public struct OverrideLabels: Equatable, Sendable {
    /// Child label name, as the board spells it, to its id.
    public var children: [String: BoardObjectID]

    public init(children: [String: BoardObjectID]) {
        self.children = children
    }

    /// Resolves the group (matched case-insensitively, groups only) and its children.
    public init(labels: [BoardLabel]) {
        let group = BoardProvisioner.overrideGroup.lowercased()
        let groupID = labels.first { $0.isGroup && $0.name.lowercased() == group }?.id
        var children: [String: BoardObjectID] = [:]
        if let groupID {
            for label in labels where label.parent == groupID && children[label.name] == nil {
                children[label.name] = label.id
            }
        }
        self.children = children
    }

    /// The Override a Card carries: the first label on the issue that is a child of the `Override`
    /// group, matched case-insensitively and spelled as the child is; nil when it carries none. Linear
    /// refuses two children of one group on an issue, so the first match is the pin.
    public func override(on object: BoardObject) -> Override? {
        let known = children.keys.sorted()
        for name in object.labels {
            if let match = known.first(where: { $0.lowercased() == name.lowercased() }) {
                return Override(label: match)
            }
        }
        return nil
    }
}
