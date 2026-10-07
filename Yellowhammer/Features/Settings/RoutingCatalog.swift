import Config
import Domain
import SwiftUI

/// What the base Routing Table pane offers besides the table itself, read from the configuration it was
/// loaded with: the declared agent CLIs and the efforts each one's adapter accepts, the Repo Roles and
/// Kinds this Mac's files already name, and which base entries a Project replaces with its own.
///
/// It supplies declared CLI controls and file-backed suggestions for Kind/Repo Role; the loader remains
/// the configuration validator, and model choices come from live CLI discovery.
struct RoutingCatalog {
    /// A declared agent CLI: its name and its adapter's efforts, least first.
    struct DeclaredCLI: Identifiable {
        let name: String
        let efforts: [String]
        let executable: String?

        init(name: String, efforts: [String], executable: String? = nil) {
            self.name = name
            self.efforts = efforts
            self.executable = executable
        }

        var id: String { name }
    }

    static let empty = RoutingCatalog(clis: [], repoRoles: [], kinds: [], replacedIn: [:])

    let clis: [DeclaredCLI]
    /// Every Repo Role a Project on this Mac declares or a Routing Entry names, sorted.
    let repoRoles: [String]
    /// Every Kind a Routing Entry on this Mac names, but the reserved authoring Kind, sorted.
    let kinds: [String]
    /// The Projects whose own entry replaces the base entry with that key.
    let replacedIn: [RoutingEntry.Key: [String]]

    func cli(named name: String) -> DeclaredCLI? { clis.first { $0.name == name } }

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

    /// An incomplete Route for the Operator to finish with a discovered model choice.
    func newRoute() -> RouteDraft {
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
        clis = machine.cliAdapters.map {
            DeclaredCLI(
                name: $0.name, efforts: RegisteredCLIAdapters.supportedEfforts[$0.name] ?? [],
                executable: $0.executable
            )
        }
        let declaredRoles = projects.flatMap(\.repos).map(\.role.rawValue)
        let namedRoles = entries.compactMap { entry -> String? in
            guard case .role(let role) = entry.repoRole else { return nil }
            return role.rawValue
        }
        repoRoles = (declaredRoles + namedRoles).uniqued().sorted()
        kinds = Self.cardKinds(entries.map(\.kind.description)).sorted()
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
    /// What Routing Table controls offer: declared CLIs, efforts, Repo Roles and Kinds.
    @Entry var routingCatalog = RoutingCatalog.empty
    /// Form-scoped one-shot model discovery and save validation state.
    @Entry var routeModelDiscovery: RouteModelDiscoveryState?
}

extension Array where Element: Hashable {
    /// The elements in order, each kept once.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
