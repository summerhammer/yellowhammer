import Config
import Domain
import Foundation

extension Doctor {
    /// Check 8, last: reach Orca ADE once, then inspect each declared Repo's registration read-only.
    func runOrcaCheck(configuration: Configuration) async -> [DoctorFinding] {
        let registered: Set<String>
        do {
            registered = Set(try await workspace.registeredRepositoryPaths().map {
                WorkspaceBinding.repositoryPath($0, homeDirectory: homeDirectory)
            })
        } catch {
            return [finding(.orca, subject: "Orca ADE", .failure, "\(error)")]
        }
        var findings: [DoctorFinding] = []
        for project in configuration.projects where projectFilter == nil || project.id == projectFilter {
            for repo in project.repos {
                let path = WorkspaceBinding.repositoryPath(repo.path, homeDirectory: homeDirectory)
                let subject = "Project \(project.id), Repo \(repo.name)"
                let isRegistered = registered.contains(path)
                let message = isRegistered
                    ? "\(subject) at \(path) is registered with Orca ADE"
                    : "\(subject) at \(path) is not registered with Orca ADE; "
                        + "rerun yh setup or run orca repo add --path \(path)"
                findings.append(finding(
                    .orca, subject: subject, isRegistered ? .pass : .failure, message, project: project.id
                ))
            }
        }
        return findings
    }
}
