import Config
import Domain

extension Setup {
    /// Step 8: proactive routing warnings (routing/overview, OQ13, OQ154). Never fails setup. With zero
    /// Projects, the machine's base Routing Table is warned about instead.
    func reportRoutingWarnings(configuration: Configuration, machine: MachineConfiguration) {
        guard !configuration.projects.isEmpty else {
            for warning in machine.routingTable.warnings {
                output("warning: \(warning)")
            }
            return
        }
        for project in configuration.projects {
            for warning in configuration.routingTable(for: project.id)?.warnings ?? [] {
                output("warning: Project \(project.id): \(warning)") // glossary:ignore GL001
            }
        }
    }
}
