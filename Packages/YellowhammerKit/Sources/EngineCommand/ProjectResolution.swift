import Config
import Domain
import Foundation

/// Loads the configuration and finds the Project an Act fires for, before any Act runs.
///
/// Missing or uninitialized configuration, and a `--project` that names an absent or invalidated
/// Project, are refused here so that `yh` exits with code 1 without running an Act (OQ13; OQ52(1):
/// a LaunchAgent left behind by a hand-deleted Project file fails fast).
enum ProjectResolution {
    static func resolve(
        projectArgument: String,
        configurationDirectory: URL
    ) throws(ProjectResolutionError) -> (Configuration, ProjectConfiguration) {
        let directory = configurationDirectory.path(percentEncoded: false)
        let machineFile = configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: machineFile.path(percentEncoded: false)) else {
            throw .uninitialized(directory: directory)
        }

        let configuration: Configuration
        do {
            configuration = try Configuration.load(directory: configurationDirectory)
        } catch {
            throw .machineConfigurationInvalid(error)
        }

        let expectedFile = configurationDirectory
            .appending(components: "projects", "\(projectArgument).toml", directoryHint: .notDirectory)
            .path(percentEncoded: false)
        // A malformed id cannot name a Project file, so it is reported as an absent Project.
        guard let id = ProjectID(rawValue: projectArgument) else {
            throw .projectNotFound(id: projectArgument, expectedFile: expectedFile)
        }
        if let project = configuration.projects.first(where: { $0.id == id }) {
            return (configuration, project)
        }
        // The id is nil when the file did not decode far enough; the decoder ties an id to its file stem.
        let invalid = configuration.invalidProjects.first { invalid in
            invalid.id == id
                || URL(filePath: invalid.file).deletingPathExtension().lastPathComponent == id.rawValue
        }
        if let invalid {
            throw .projectInvalidated(id: id, file: invalid.file, errors: invalid.errors)
        }
        throw .projectNotFound(id: projectArgument, expectedFile: expectedFile)
    }
}
