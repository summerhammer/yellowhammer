import Domain

/// A place the Settings window can show. The sidebar's rows are these, and `SettingsHistory` is a list
/// of them.
enum SettingsSection: Hashable {
    /// The machine-wide settings: the Linear installation, the Operator identity and Orca ADE.
    case general
    /// The declared Agent CLIs, their latest Probe Results, and a Probe on demand.
    case agentCLIs
    /// The machine-wide base Routing Table.
    case baseRoutingTable
    /// The Project configuration files the loader refused, with their errors.
    case refusedFiles
    /// One configured Project's Configuration and Recalibrate.
    case project(ProjectID)

    /// The name the toolbar and the window's title show. A Project shows its configured name; an id that
    /// is not (yet) configured shows the id itself.
    func title(in configured: ConfiguredProjects?) -> String {
        switch self {
        case .general: "General"
        case .agentCLIs: "Agent CLIs"
        case .baseRoutingTable: "Base Routing Table"
        case .refusedFiles: "Refused Files"
        case let .project(id): configured?.entry(for: id)?.name ?? id.rawValue
        }
    }
}
