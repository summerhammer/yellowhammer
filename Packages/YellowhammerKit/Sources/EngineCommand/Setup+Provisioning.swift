import Config
import Domain
import Engine

extension Setup {
    /// Step 6: provisions every valid Project. A `BoardError` for one Project is printed and setup
    /// continues with the next; returns whether any Project failed.
    func provisionProjects(
        configuration: Configuration, machine: MachineConfiguration, secret: String
    ) async -> Bool {
        var anyFailed = false
        for project in configuration.projects {
            do {
                let board = try bindProvisioning(machine, project.linearProject, secret)
                let report = try await BoardProvisioner.provision(
                    using: board, projectName: project.name, createIn: nil,
                    routingTable: configuration.routingTable(for: project.id) ?? RoutingTable(entries: [])
                )
                output("Project \(project.id):") // glossary:ignore GL001
                output(report.isChanged ? report.description : "  no changes")
            } catch {
                output("Project \(project.id): \(error)") // glossary:ignore GL001
                anyFailed = true
            }
        }
        return anyFailed
    }
}
