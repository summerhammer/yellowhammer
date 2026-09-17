import Domain
import Foundation

extension BoardProvisioner {
    /// The three mutually exclusive Override label groups (Decision Gates Ruling, G-17), each pinning
    /// one axis of the Route.
    static let overrideCLIGroup = "Override CLI"
    static let overrideModelGroup = "Override Model"
    static let overrideEffortGroup = "Override Effort"
}

/// The values the Override label groups are provisioned with: every distinct `cli`, `model` and
/// `effort` across the merged Routing Table's routes and fallbacks, sorted. Setup provisions from
/// these and refreshes them when the table changes (G-17).
public struct OverrideLabelValues: Equatable, Sendable {
    public var clis: [String]
    public var models: [String]
    public var efforts: [String]

    public init(clis: [String], models: [String], efforts: [String]) {
        self.clis = clis
        self.models = models
        self.efforts = efforts
    }

    public init(table: RoutingTable) {
        let routes = table.entries.flatMap { [$0.route] + $0.fallbacks }
        clis = Set(routes.map(\.cli)).sorted()
        models = Set(routes.map(\.model)).sorted()
        efforts = Set(routes.map(\.effort)).sorted()
    }
}

/// The Override label groups as a team exposes them, resolved from the labels the board reports: the
/// children of each group, by name. A group the team does not have means that axis cannot be pinned
/// on it — not an error, because a team is provisioned from its Projects' tables and a Card carries an
/// Override only when the Operator set one.
public struct OverrideLabels: Equatable, Sendable {
    /// Child label name, as the board spells it, to its id — per axis.
    public var cli: [String: BoardObjectID]
    public var model: [String: BoardObjectID]
    public var effort: [String: BoardObjectID]

    public init(cli: [String: BoardObjectID], model: [String: BoardObjectID], effort: [String: BoardObjectID]) {
        self.cli = cli
        self.model = model
        self.effort = effort
    }

    /// Resolves the three groups (matched case-insensitively, groups only) and their children.
    public init(labels: [BoardLabel]) {
        cli = Self.children(of: BoardProvisioner.overrideCLIGroup, in: labels)
        model = Self.children(of: BoardProvisioner.overrideModelGroup, in: labels)
        effort = Self.children(of: BoardProvisioner.overrideEffortGroup, in: labels)
    }

    /// The Override a Card carries: one pin per group whose child label is on the issue, matched
    /// case-insensitively by name, spelled as the group's child is. A label on the issue that is not a
    /// child of an Override group pins nothing. Linear refuses two children of one group on an issue,
    /// so the first match per group is the pin.
    public func override(on object: BoardObject) -> Override {
        Override(
            cli: Self.pin(from: object.labels, in: cli),
            model: Self.pin(from: object.labels, in: model),
            effort: Self.pin(from: object.labels, in: effort)
        )
    }

    private static func children(of group: String, in labels: [BoardLabel]) -> [String: BoardObjectID] {
        let groupID = labels.first { $0.isGroup && $0.name.lowercased() == group.lowercased() }?.id
        guard let groupID else {
            return [:]
        }
        var children: [String: BoardObjectID] = [:]
        for label in labels where label.parent == groupID && children[label.name] == nil {
            children[label.name] = label.id
        }
        return children
    }

    private static func pin(from names: [String], in children: [String: BoardObjectID]) -> String? {
        let known = children.keys.sorted()
        for name in names {
            if let match = known.first(where: { $0.lowercased() == name.lowercased() }) {
                return match
            }
        }
        return nil
    }
}
