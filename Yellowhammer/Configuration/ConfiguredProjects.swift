import Config
import Domain
import Foundation

/// Every configured Project's id and name, and nothing else. The temporary Project Window, the Setup
/// wizard and the updater's live-Lease scan read it. The main window reads the whole configuration
/// through `OverviewModel`.
///
/// Read from the TOML files each time it is asked for, never watched or kept: the files are the only
/// record, and the Operator may edit them while the app is open.
struct ConfiguredProjects: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: ProjectID
        let name: String
    }

    /// In configured order, the same order as the main window's Sidebar: the order the loader returns,
    /// which is by id.
    let entries: [Entry]
    /// Why nothing could be read, in the loader's own words; nil when the configuration loaded.
    let loadFailure: String?

    /// The launch argument that points the app at another configuration directory, for UI tests
    /// (`-YellowhammerConfigurationDirectory <path>`). Only the argument domain is read, so it cannot
    /// persist through `defaults write`.
    static let directoryArgument = ConfigurationDirectory.argument

    static func load() -> ConfiguredProjects {
        do {
            // A Mac where Setup has never run configures no Projects; that is not a load failure.
            guard let configuration = try Configuration.loadIfSetUp(directory: ConfigurationDirectory.current) else {
                return ConfiguredProjects(entries: [], loadFailure: nil)
            }
            let entries = configuration.projects.map { Entry(id: $0.id, name: $0.name) }
            return ConfiguredProjects(entries: entries, loadFailure: nil)
        } catch {
            return ConfiguredProjects(entries: [], loadFailure: error.description)
        }
    }

    func entry(for id: ProjectID?) -> Entry? {
        entries.first { $0.id == id }
    }
}
