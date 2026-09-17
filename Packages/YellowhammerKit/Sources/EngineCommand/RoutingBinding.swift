import Config
import Domain
import Engine
import Ledger

/// Builds the route resolver for one resolved Project (roadmap P7.6): the Project's merged Routing
/// Table from the Configuration this invocation loaded, and the Probe verdict read from the
/// machine-wide Ledger. The Engine never reads configuration and never opens the Ledger; this is the
/// one place both are bound. Configuration is loaded on every Act, so the table is read fresh each
/// time — nothing about it is learned or inferred. The build Act's Card loop (P8.4) is what calls it.
enum RoutingBinding {
    static func resolver(
        configuration: Configuration,
        projectID: ProjectID,
        ledger: LedgerStore
    ) throws(RoutingBindingError) -> RouteResolver {
        guard let table = configuration.routingTable(for: projectID) else {
            throw .projectNotLoaded(projectID)
        }
        return RouteResolver(table: table) { cli in
            try ledger.routeTargetEligibility(cli: cli)
        }
    }
}

/// The Project has no merged Routing Table: it was not loaded, or was refused at load.
enum RoutingBindingError: Error, Equatable, Sendable, CustomStringConvertible {
    case projectNotLoaded(ProjectID)

    var description: String {
        switch self {
        case .projectNotLoaded(let id):
            "Project '\(id)' has no Routing Table: it was not loaded or was refused at load"
        }
    }
}
