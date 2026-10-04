import Config
import Domain
import SwiftUI

/// What the base Routing Table pane offers besides the table itself, read from the configuration it was
/// loaded with: the declared agent CLIs and the efforts each one's adapter accepts, the Repo Roles and
/// Kinds this Mac's files already name, and which base entries a Project replaces with its own.
///
/// Everything here is a suggestion: the loader stays the single validator, so a Route naming a CLI that is
/// not declared, or a Kind no file names yet, is still drawn and refused only on save.
struct RoutingCatalog {
    /// A declared agent CLI: its name and its adapter's efforts, least first.
    struct DeclaredCLI: Identifiable {
        let name: String
        let efforts: [String]

        var id: String { name }
    }

    static let empty = RoutingCatalog(clis: [], repoRoles: [], kinds: [], models: [:], replacedIn: [:])

    let clis: [DeclaredCLI]
    /// Every Repo Role a Project on this Mac declares or a Routing Entry names, sorted.
    let repoRoles: [String]
    /// Every Kind a Routing Entry on this Mac names, but the reserved authoring Kind, sorted.
    let kinds: [String]
    /// Every model a Route on this Mac names, by CLI, in the order first named.
    let models: [String: [String]]
    /// The Projects whose own entry replaces the base entry with that key.
    let replacedIn: [RoutingEntry.Key: [String]]

    func cli(named name: String) -> DeclaredCLI? { clis.first { $0.name == name } }

    /// The models to suggest for `cli`: those named with it anywhere on this Mac, then those `table` names.
    func models(for cli: String, in table: [RoutingEntryDraft]) -> [String] {
        let named = table.flatMap(\.chain).filter { $0.cli == cli && !$0.model.isEmpty }.map(\.model)
        return (models[cli, default: []] + named).uniqued()
    }

    /// Every Kind worth offering for `table`: the catalog's and every valid Kind the table names, sorted.
    func kinds(in table: [RoutingEntryDraft]) -> [String] {
        Self.cardKinds(kinds + table.map(\.kind)).sorted()
    }

    /// The Projects that replace `entry` with their own.
    func projectsReplacing(_ entry: RoutingEntryDraft) -> [String] {
        entry.key.flatMap { replacedIn[$0] } ?? []
    }

    /// The effort to keep when a Route moves to `cli`: the same one if that CLI's adapter accepts it, else
    /// `medium`, else its least.
    func effort(_ effort: String, carriedTo cli: String) -> String {
        guard let efforts = self.cli(named: cli)?.efforts, !efforts.isEmpty else { return effort }
        if efforts.contains(effort) { return effort }
        return efforts.contains("medium") ? "medium" : efforts[0]
    }

    /// A Route none of `taken` is, for a new verifier: a declared CLI with a model this Mac already names
    /// for it, at `high` where its adapter accepts it. When every such Route is taken, or none exists, the
    /// first declared CLI with no model, for the Operator to finish.
    func route(avoiding taken: [RouteDraft]) -> RouteDraft {
        let offered = clis.flatMap { cli in
            models[cli.name, default: []].map {
                RouteDraft(cli: cli.name, model: $0, effort: effort("high", carriedTo: cli.name))
            }
        }
        if let free = offered.first(where: { !taken.contains($0) }) { return free }
        let cli = clis.first?.name ?? ""
        return RouteDraft(cli: cli, model: "", effort: effort("high", carriedTo: cli))
    }

    /// Valid, non-reserved Kinds out of `strings`, once each.
    private static func cardKinds(_ strings: [String]) -> [String] {
        strings
            .compactMap { Kind($0) }
            .filter { $0 != .any && !$0.isReservedForAuthoring }
            .map(\.description)
            .uniqued()
    }
}

extension RoutingCatalog {
    /// The catalog for a machine file and the Projects loaded beside it.
    init(machine: MachineConfiguration, projects: [ProjectConfiguration]) {
        let entries = machine.routingTable + projects.flatMap(\.routingOverrides)
        let routes = entries.flatMap { [$0.route] + $0.fallbacks }
        clis = machine.cliAdapters.map {
            DeclaredCLI(name: $0.name, efforts: RegisteredCLIAdapters.supportedEfforts[$0.name] ?? [])
        }
        let declaredRoles = projects.flatMap(\.repos).map(\.role.rawValue)
        let namedRoles = entries.compactMap { entry -> String? in
            guard case .role(let role) = entry.repoRole else { return nil }
            return role.rawValue
        }
        repoRoles = (declaredRoles + namedRoles).uniqued().sorted()
        kinds = Self.cardKinds(entries.map(\.kind.description)).sorted()
        models = Dictionary(grouping: routes, by: \.cli).mapValues { $0.map(\.model).uniqued() }
        var replacedIn: [RoutingEntry.Key: [String]] = [:]
        let baseKeys = Set(machine.routingTable.map(\.key))
        for project in projects {
            for entry in project.routingOverrides where baseKeys.contains(entry.key) {
                replacedIn[entry.key, default: []].append(project.name)
            }
        }
        self.replacedIn = replacedIn
    }
}

extension EnvironmentValues {
    /// What the base Routing Table pane's controls offer: its CLIs, efforts, models, Repo Roles and Kinds.
    @Entry var routingCatalog = RoutingCatalog.empty
}

extension Array where Element: Hashable {
    /// The elements in order, each kept once.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
