import Config
import Domain
import Engine
import Foundation

/// Chooses the Dispatch seam's implementation for a Night, shared by every Act that dispatches an agent
/// CLI — the build Act's Card run and the author Act's selection and breakdown (roadmap P9.11): a
/// Rehearsal Night never dispatches an agent CLI, so it gets ``RehearsalDispatch``; a real Night gets
/// ``CLIAdapterDispatch``.
enum DispatchBinding {
    static func dispatch(
        mode: NightMode,
        configuration: Configuration,
        project: ProjectConfiguration,
        configurationDirectory: URL,
        resultFixtures: RehearsalScript = RehearsalScript.empty
    ) -> any AgentDispatch {
        switch mode {
        case .rehearsal:
            return RehearsalDispatch(script: resultFixtures)
        case .real:
            var declared: [String: String] = [:]
            for adapter in configuration.machine.cliAdapters {
                declared[adapter.name] = adapter.executable
            }
            return CLIAdapterDispatch(
                runsDirectory: CLIAdapterDispatch.runsDirectory(
                    configurationDirectory: configurationDirectory, projectID: project.id
                ),
                declaredExecutables: declared
            )
        }
    }
}
