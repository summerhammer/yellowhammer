import Config
import Domain
import Engine

extension Setup {
    /// Step 6: provisions every valid Project. A `BoardError` for one Project is printed and setup
    /// continues with the next. Returns the ids of every Project whose provisioning failed, so step 6.5
    /// (scheduled jobs) can exclude them, plus each Project's own unfinished-steps report — the story's
    /// consolidated list, printed once by ``reportUnfinishedProvisioning(_:)`` at the end of setup's
    /// output.
    func provisionProjects(
        configuration: Configuration, machine: MachineConfiguration
    ) async -> (failed: Set<ProjectID>, unfinished: [(ProjectID, ProvisioningReport)]) {
        var failed: Set<ProjectID> = []
        var unfinished: [(ProjectID, ProvisioningReport)] = []
        for project in configuration.projects {
            do {
                let board = bindProvisioning(machine, project.linearProject)
                let report = try await BoardProvisioner.provision(
                    using: board, projectName: project.name, createIn: nil,
                    routingTable: configuration.routingTable(for: project.id) ?? RoutingTable(entries: [])
                )
                output("Project \(project.id):") // glossary:ignore GL001
                // A lingering refusal must still be named on a re-run that changes nothing, so the
                // per-item "permission refused"/"not a member" lines are never silently dropped.
                output(report.isChanged || report.hasUnfinishedSteps ? report.description : "  no changes")
                if report.hasUnfinishedSteps {
                    unfinished.append((project.id, report))
                }
            } catch {
                output("Project \(project.id): \(error)") // glossary:ignore GL001
                failed.insert(project.id)
            }
        }
        return (failed, unfinished)
    }

    /// "Setup lists each unfinished step at the end": one consolidated list across every Project,
    /// printed as the last block of setup's output, followed by the create-by-hand guideline for the
    /// permission-refused items only — a not-a-member team gets the membership fix instead, since
    /// nothing can be created by hand until the app is added.
    func reportUnfinishedProvisioning(_ unfinished: [(ProjectID, ProvisioningReport)]) {
        guard !unfinished.isEmpty else { return }
        output("Unfinished provisioning steps:")
        for (projectID, report) in unfinished {
            output("Project \(projectID):") // glossary:ignore GL001
            output(report.unfinishedDescription)
        }
        for guideline in Set(unfinished.compactMap { $0.1.createByHandGuideline }) {
            output(guideline)
        }
    }
}
