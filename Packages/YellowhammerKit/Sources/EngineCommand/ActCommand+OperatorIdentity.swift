import Config
import Domain
import Engine

extension ActCommand {
    /// The Operator identity of `project`'s own App Installation; unconfigured when the registry lacks it.
    static func operatorIdentity(configuration: Configuration, project: ProjectConfiguration) -> OperatorIdentity {
        OperatorIdentity(configured: configuration.machine.linearInstallation(for: project)?.operatorIdentity)
    }
}
