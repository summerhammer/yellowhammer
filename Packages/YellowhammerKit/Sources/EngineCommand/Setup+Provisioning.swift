import Config
import Domain
import Engine

extension Setup {
    /// Step 6: provisions every valid Project. A `BoardError` for one Project is printed and setup
    /// continues with the next; returns the ids of every Project whose provisioning failed, so step 6.5
    /// (scheduled jobs) can exclude them.
    func provisionProjects(
        configuration: Configuration, machine: MachineConfiguration, secret: String
    ) async -> Set<ProjectID> {
        var failed: Set<ProjectID> = []
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
                failed.insert(project.id)
            }
        }
        return failed
    }
}
