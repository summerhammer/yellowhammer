import Domain

/// A place the Settings window can show. The sidebar's rows are these, and `SettingsHistory` is a list
/// of them.
enum SettingsSection: Hashable {
    /// The machine-wide settings. They move here from their own windows in later steps.
    case general
    /// The Project configuration files the loader refused, with their errors.
    case refusedFiles
    /// One configured Project's Configuration and Recalibrate.
    case project(ProjectID)

    /// The name the toolbar and the window's title show. A Project shows its configured name; an id that
    /// is not (yet) configured shows the id itself.
    func title(in configured: ConfiguredProjects?) -> String {
        switch self {
        case .general: "General"
        case .refusedFiles: "Refused Files"
        case let .project(id): configured?.entry(for: id)?.name ?? id.rawValue
        }
    }
}
