import Config
import Domain
import Foundation

/// Every configured Project's id and name, and the Project files that were refused. The temporary Project
/// Window, the Setup wizard, the updater's live-Lease scan and the Settings window read it. The main
/// window reads the whole configuration through `OverviewModel`.
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
    /// The Project files the loader refused, with their errors. They are never in `entries` (OQ79).
    var refused: [InvalidProject] = []
    /// The Entry `yh project remove` would act on, for each refused file that has one, keyed by the file's
    /// path. It mirrors `yh`'s own resolution (the lenient load, then the file's id or stem), so the
    /// Settings window offers removal only where `yh` would act; `yh` re-checks it anyway.
    var removable: [String: Entry] = [:]

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
            let refused = configuration.invalidProjects
            return ConfiguredProjects(
                entries: entries, loadFailure: nil, refused: refused, removable: removableEntries(for: refused)
            )
        } catch {
            return ConfiguredProjects(entries: [], loadFailure: error.description)
        }
    }

    /// The lenient load's Project for each refused file, matched the way `ProjectResolution` matches an id
    /// to a refused file: the file's decoded id, or its stem. A lenient failure leaves nothing removable.
    private static func removableEntries(for refused: [InvalidProject]) -> [String: Entry] {
        guard !refused.isEmpty,
            let lenient = try? Configuration.loadLeniently(directory: ConfigurationDirectory.current)
        else { return [:] }
        var result: [String: Entry] = [:]
        for file in refused {
            let stem = URL(filePath: file.file).deletingPathExtension().lastPathComponent
            if let project = lenient.projects.first(where: { $0.id == file.id || $0.id.rawValue == stem }) {
                result[file.file] = Entry(id: project.id, name: project.name)
            }
        }
        return result
    }

    /// The Entry `yh` would remove for a refused file, or nil when it would refuse.
    func removableEntry(for file: InvalidProject) -> Entry? {
        removable[file.file]
    }

    func entry(for id: ProjectID?) -> Entry? {
        entries.first { $0.id == id }
    }
}
