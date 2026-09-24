import Config
import Domain

/// Why an Act was refused before it ran. `yh` prints the description and exits with code 1.
public enum ProjectResolutionError: Error, Equatable, Sendable {
    /// The configuration directory, or its `config.toml`, does not exist.
    case uninitialized(directory: String)
    /// `config.toml` failed to load; it is load-bearing for every Project.
    case machineConfigurationInvalid(ConfigurationError)
    /// `--project` names no Project file, or is not a valid Project id.
    case projectNotFound(id: String, expectedFile: String)
    /// The Project's file exists but the Project was refused at load.
    case projectInvalidated(id: ProjectID, file: String, errors: [ConfigurationError])
    /// `--project` was omitted and more than one Project is configured, so none can be defaulted to.
    case projectRequired(ids: [String])
}

extension ProjectResolutionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .uninitialized(let directory):
            return """
                Yellowhammer is not configured: no config.toml in \(directory). No Act was run.
                Run `yh setup` or open Yellowhammer.app to configure it.
                """
        case .machineConfigurationInvalid(let error):
            return """
                The machine-wide configuration could not be loaded. No Act was run.
                  \(error)
                Fix the file, or run `yh setup` or open Yellowhammer.app.
                """
        case .projectNotFound(let id, let expectedFile):
            return """
                No Project "\(id)" is configured: \(expectedFile) does not exist. No Act was run.
                Run `yh setup` or open Yellowhammer.app to declare it. If the Project was removed, \
                unload its LaunchAgents with `yh doctor --fix`.
                """
        case .projectInvalidated(let id, let file, let errors):
            let lines = errors.map { "  \($0)" }.joined(separator: "\n")
            return """
                Project "\(id)" was refused at load (\(file)). No Act was run.
                \(lines)
                Fix the configuration, or run `yh setup` or open Yellowhammer.app.
                """
        case .projectRequired(let ids):
            return "--project <id> is required: more than one Project is configured (\(ids.joined(separator: ",")))."
        }
    }
}
