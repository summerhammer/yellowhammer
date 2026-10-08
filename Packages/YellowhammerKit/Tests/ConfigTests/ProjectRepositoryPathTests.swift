import Config
import Domain
import Foundation
import Testing

@Test("Domain repositories expand home paths while configuration retains its spelling", arguments: [false, true])
func projectRepositoriesExpandHomePaths(specRepo: Bool) throws {
    let configuration = ProjectConfiguration(
        id: try #require(ProjectID(rawValue: "home-paths")), name: "Home paths",
        linearInstallationName: "acme", linearProject: "HOME", codeHostingConnectionName: "github",
        specSource: specRepo ? nil : "~/dev/spec",
        repos: [
            RepoDeclaration(
                name: "backend", path: "~/dev/backend", role: .backend,
                check: .command("swift test"), protectedPaths: ["Secrets/"]
            )
        ] + (specRepo ? [RepoDeclaration(name: "spec", path: "~/dev/spec", role: .spec, check: .none)] : [])
    )
    let home = FileManager.default.homeDirectoryForCurrentUser
    let repositories = configuration.projectRepositories

    #expect(repositories.workingRepo(named: "backend") == Repo(
        name: "backend", path: home.appending(path: "dev/backend").path(percentEncoded: false),
        role: .backend, protectedPaths: ["Secrets/"]
    ))
    #expect(repositories.specificationSource?.path == home.appending(path: "dev/spec").path(percentEncoded: false))
    #expect(configuration.repos[0].path == "~/dev/backend")
    #expect(configuration.repos[0].check == .command("swift test"))
    if specRepo {
        #expect(configuration.repos[1].path == "~/dev/spec")
    } else {
        #expect(configuration.specSource == "~/dev/spec")
    }
    #expect(configuration.repositories == repositories)
}

@Test("Domain repositories preserve absolute and relative paths", arguments: ["/repos/backend", "repos/backend"])
func projectRepositoriesPreserveNonHomePaths(path: String) throws {
    let configuration = ProjectConfiguration(
        id: try #require(ProjectID(rawValue: "other-paths")), name: "Other paths",
        linearInstallationName: "acme", linearProject: "OTHER", codeHostingConnectionName: "github",
        specSource: path,
        repos: [RepoDeclaration(name: "backend", path: path, role: .backend, check: .none)]
    )

    #expect(configuration.repositories.workingRepo(named: "backend")?.path == path)
    #expect(configuration.repositories.specificationSource?.path == path)
}
