import Config
import Domain
import Foundation

extension Setup {
    /// Register every declared Repo, including a Repo with the spec role. A Spec Source is not a Repo.
    /// Registration failures make that Project ineligible for scheduled jobs.
    func registerRepositories(configuration: Configuration) async -> (failedIDs: Set<ProjectID>, failed: Bool) {
        var registered: Set<String>
        do {
            registered = Set(try await workspace.registeredRepositoryPaths().map {
                WorkspaceBinding.repositoryPath($0, homeDirectory: homeDirectory)
            })
        } catch {
            for project in configuration.projects {
                for repo in project.repos {
                    output("Project \(project.id), Repo \(repo.name) at \(repo.path): \(error)")
                }
            }
            if configuration.projects.isEmpty { output("Orca ADE registration: \(error)") }
            return (Set(configuration.projects.map(\.id)), true)
        }
        var failed: Set<ProjectID> = []
        for project in configuration.projects {
            for repo in project.repos {
                let path = WorkspaceBinding.repositoryPath(repo.path, homeDirectory: homeDirectory)
                let subject = "Project \(project.id), Repo \(repo.name) at \(path)"
                if registered.contains(path) {
                    output("\(subject): already registered with Orca ADE")
                    continue
                }
                do {
                    try await workspace.registerRepository(path: path)
                    registered.insert(path)
                    output("\(subject): registered with Orca ADE")
                } catch {
                    failed.insert(project.id)
                    output("\(subject): registration failed: \(error)")
                }
            }
        }
        return (failed, !failed.isEmpty)
    }
}
