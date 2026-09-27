import Config
import Domain
import Testing

private func credential(_ string: String) throws -> CredentialReference {
    try #require(CredentialReference(string))
}

private func machineConfiguration(gitHubCredential: CredentialReference) throws -> MachineConfiguration {
    MachineConfiguration(
        linearCredential: try credential("keychain:linear"),
        gitHubCredential: gitHubCredential,
        cliAdapters: [],
        routingTable: []
    )
}

private func projectConfiguration(gitHubCredential: CredentialReference?) throws -> ProjectConfiguration {
    ProjectConfiguration(
        id: try #require(ProjectID(rawValue: "sample")),
        name: "Sample Project",
        linearProject: "SAMPLE",
        specSource: "~/dev/sample-spec",
        repos: [RepoDeclaration(name: "app", path: "~/dev/sample/app", role: .backend, check: .none)],
        gitHubCredential: gitHubCredential
    )
}

@Suite("GitHub credential selection")
struct GitHubCredentialSelectionTests {

    @Test("A Project's own GitHub credential overrides the machine default")
    func projectOverrideWins() throws {
        let machine = try machineConfiguration(gitHubCredential: credential("keychain:github-machine"))
        let project = try projectConfiguration(gitHubCredential: try credential("keychain:github-project"))

        #expect(machine.gitHubCredential(for: project) == (try credential("keychain:github-project")))
    }

    @Test("With no Project override, the machine default GitHub credential applies")
    func machineDefaultApplies() throws {
        let machine = try machineConfiguration(gitHubCredential: credential("keychain:github-machine"))
        let project = try projectConfiguration(gitHubCredential: nil)

        #expect(machine.gitHubCredential(for: project) == (try credential("keychain:github-machine")))
    }
}
