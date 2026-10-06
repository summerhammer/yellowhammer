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
            return CLIAdapterDispatch(
                runsDirectory: CLIAdapterDispatch.runsDirectory(
                    configurationDirectory: configurationDirectory, projectID: project.id
                ),
                declaredExecutables: declaredExecutables(configuration)
            )
        }
    }

    /// The Route Pre-flight seam's implementation for a Night (OQ126), chosen the same way: a Rehearsal
    /// Night never runs an agent CLI, so its pre-flight is a fixture answer.
    static func routePreflight(
        mode: NightMode,
        configuration: Configuration,
        project: ProjectConfiguration,
        configurationDirectory: URL
    ) -> any RoutePreflighting {
        switch mode {
        case .rehearsal:
            RehearsalRoutePreflight()
        case .real:
            CLIAdapterRoutePreflight(
                runsDirectory: CLIAdapterDispatch.runsDirectory(
                    configurationDirectory: configurationDirectory, projectID: project.id
                ),
                declaredExecutables: declaredExecutables(configuration)
            )
        }
    }

    /// Each declared CLI Adapter's executable from the machine configuration, by CLI name.
    private static func declaredExecutables(_ configuration: Configuration) -> [String: String] {
        var declared: [String: String] = [:]
        for adapter in configuration.machine.cliAdapters {
            declared[adapter.name] = adapter.executable
        }
        return declared
    }
}
