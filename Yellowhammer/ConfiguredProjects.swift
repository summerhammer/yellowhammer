import Config
import Domain
import Foundation

/// The Projects the app can scope a window to: every configured Project's id and name, and nothing
/// else (OQ52 Face 2).
///
/// Read from the TOML files each time it is asked for, never watched or kept: the files are the only
/// record, and the Operator may edit them while the app is open.
struct ConfiguredProjects: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: ProjectID
        let name: String
    }

    /// Sorted by name, so the selector reads as a list of names.
    let entries: [Entry]
    /// Why nothing could be read, in the loader's own words; nil when the configuration loaded.
    let loadFailure: String?

    /// The launch argument that points the app at another configuration directory, for UI tests
    /// (`-YellowhammerConfigurationDirectory <path>`). Only the argument domain is read, so it cannot
    /// persist through `defaults write`.
    static let directoryArgument = ConfigurationDirectory.argument

    static func load() -> ConfiguredProjects {
        do {
            let configuration = try Configuration.load(directory: ConfigurationDirectory.current)
            let entries = configuration.projects
                .map { Entry(id: $0.id, name: $0.name) }
                .sorted {
                    switch $0.name.localizedStandardCompare($1.name) {
                    case .orderedAscending: true
                    case .orderedDescending: false
                    case .orderedSame: $0.id.rawValue < $1.id.rawValue
                    }
                }
            return ConfiguredProjects(entries: entries, loadFailure: nil)
        } catch {
            return ConfiguredProjects(entries: [], loadFailure: error.description)
        }
    }

    func entry(for id: ProjectID?) -> Entry? {
        entries.first { $0.id == id }
    }
}
