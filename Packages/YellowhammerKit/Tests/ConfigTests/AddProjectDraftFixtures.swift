import Config
import Domain
import Foundation

/// A registry entry `completeAddProjectDraft()` selects: it has an Operator identity.
func addProjectInstallation(
    name: String = "acme", workspace: String = "workspace-1", operatorIdentity: String? = "user-1"
) -> LinearInstallation {
    guard let credential = CredentialReference("keychain:linear-\(name)") else {
        preconditionFailure("fixture credential")
    }
    return LinearInstallation(
        name: name,
        credential: credential,
        workspace: BoardObjectID(rawValue: workspace),
        appUser: BoardObjectID(rawValue: "app-user-\(name)"),
        operatorIdentity: operatorIdentity.flatMap { BoardObjectID(rawValue: $0) }
    )
}

/// A draft that is complete: every step passes.
func completeAddProjectDraft() -> AddProjectDraft {
    var draft = AddProjectDraft()
    draft.setName("Acme")
    draft.context.linearInstallations = [addProjectInstallation()]
    draft.selectLinearInstallation("acme")
    draft.linearProjectID = "ACME"
    draft.linearVerification = .verified(name: "Acme", teamNames: ["Engineering"])
    draft.addRepo(path: "/work/acme-backend")
    draft.repos[0].check = "make test"
    draft.useSpecSource("/work/acme-spec")
    draft.codeHostingConnectionName = "github"
    draft.codeHostingCheckedConnectionName = "github"
    draft.context.codeHostingConnections = [
            CodeHostingConnection(name: "github", kind: .keychainToken(.init("keychain:github")!))
        ]
    draft.gitHubReport = validGitHubReport(repoPaths: draft.workingRepoPaths)
    draft.gitHubCheckedRepoPaths = draft.workingRepoPaths
    // Bounds and the Schedule are complete at their defaults once opened.
    draft.visited.formUnion([.bounds, .jobs])
    return draft
}

/// A GitHub check that found the token good for a user and able to push to each of `repoPaths`.
func validGitHubReport(repoPaths: [String]) -> GitHubCredentialReport {
    GitHubCredentialReport(
        reference: "keychain:github", state: .resolves, login: "octocat", message: "The token belongs to octocat.",
        repos: repoPaths.map {
            let name = URL(filePath: $0).lastPathComponent
            return GitHubCredentialReport.Repo(
                name: name, path: $0, slug: "acme/\(name)", status: .ok, message: "Repo \(name): the token can push."
            )
        }
    )
}
