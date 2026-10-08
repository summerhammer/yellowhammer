import ArgumentParser
import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

/// Feeds ``SetupInvocation``'s built argument vectors back through `SetupCommand`'s own parser, so the
/// app's argument-building contract and `yh setup`'s flag spelling can never silently drift apart.
@Suite("SetupInvocation ↔ SetupCommand contract")
struct SetupInvocationContractTests {
    @Test("A full --init invocation parses back to the matching SetupOptions") // glossary:ignore GL001
    func fullInitInvocationParsesBack() throws {
        let invocation = SetupInvocation(
            boardConnection: "main",
            githubCredential: "keychain:github",
            cliAdapters: ["claude"],
            route: "claude/sonnet/medium",
            fallbacks: ["claude/opus/high"],
            operatorID: "user-op",
            project: SetupInvocation.Project(
                id: "demo", name: "Demo", linearProject: .existing("proj-1"),
                specSource: "~/dev/demo-spec",
                repos: [
                    SetupInvocation.Repo(name: "backend", role: "backend", path: "~/dev/backend", check: "swift test")
                ]
            ),
            jobs: .export(directory: "/tmp/jobs", cron: true)
        )
        let arguments = Array(try invocation.arguments().dropFirst())

        let command = try SetupCommand.parse(arguments)
        let options = try SetupOptions(command: command)

        #expect(options.mode == .initialize)
        #expect(options.installation == "main")
        #expect(options.githubCredential == CredentialReference("keychain:github"))
        #expect(options.cliAdapters == [CLIAdapterDeclaration(name: "claude")])
        #expect(options.route?.route == Route(cli: "claude", model: "sonnet", effort: "medium"))
        #expect(options.route?.fallbacks ?? [] == [Route(cli: "claude", model: "opus", effort: "high")])
        #expect(options.operatorID == BoardObjectID(rawValue: "user-op"))
        #expect(options.projectID == ProjectID(rawValue: "demo"))
        #expect(options.projectName == "Demo")
        #expect(options.linearProjectID == "proj-1")
        #expect(options.linearTeam == nil)
        #expect(options.specSource == "~/dev/demo-spec")
        #expect(options.repos == [
            RepoDeclaration(
                name: "backend", path: "~/dev/backend", role: RepoRole(rawValue: "backend"),
                check: .command("swift test")
            )
        ])
        #expect(options.jobs == .export(URL(filePath: "/tmp/jobs", directoryHint: .isDirectory), format: .cron))
    }

    @Test("A createInTeam Project parses back as --linear-team") // glossary:ignore GL001
    func createInTeamParsesBack() throws {
        let invocation = SetupInvocation(
            project: SetupInvocation.Project(id: "demo", linearProject: .createInTeam(key: "ENG"))
        )
        let arguments = Array(try invocation.arguments().dropFirst())

        let command = try SetupCommand.parse(arguments)
        let options = try SetupOptions(command: command)

        #expect(options.linearTeam == "ENG")
        #expect(options.linearProjectID == nil)
    }

    @Test("installLinearArguments with a name parses back with --board-connection-name") // glossary:ignore GL001
    func installLinearWithNameParsesBack() throws {
        let built = SetupInvocation.installLinearArguments(boardConnectionName: "work", remote: true)
        let arguments = Array(built.dropFirst())

        let options = try SetupOptions(command: try SetupCommand.parse(arguments))

        #expect(options.mode == .installLinear)
        #expect(options.installationName == "work")
        #expect(options.installation == nil)
        #expect(options.eventsJSON)
        #expect(options.remoteApproval)
    }

    @Test("An --init invocation's boardConnectionName parses back")
    func initInstallationNameParsesBack() throws {
        let arguments = Array(try SetupInvocation(boardConnectionName: "work").arguments().dropFirst())

        let options = try SetupOptions(command: try SetupCommand.parse(arguments))

        #expect(options.mode == .initialize)
        #expect(options.installationName == "work")
    }

    @Test("choicesArguments parses back as --print-choices, no Project or generating options") // glossary:ignore GL001
    func choicesArgumentsParsesBack() throws {
        let arguments = Array(SetupInvocation.choicesArguments(
            boardConnection: "main", githubCredential: "keychain:github"
        ).dropFirst())

        let command = try SetupCommand.parse(arguments)
        let options = try SetupOptions(command: command)

        #expect(options.mode == .printChoices)
        #expect(options.installation == "main")
        #expect(options.githubCredential == CredentialReference("keychain:github"))
        #expect(options.projectID == nil)
        #expect(options.linearProjectID == nil)
    }

    @Test("choicesArguments with linearProject parses back with linearProjectID") // glossary:ignore GL001
    func choicesArgumentsWithLinearProjectParsesBack() throws {
        let arguments = Array(SetupInvocation.choicesArguments(
            boardConnection: "main", githubCredential: nil, linearProject: "proj-1"
        ).dropFirst())

        let command = try SetupCommand.parse(arguments)
        let options = try SetupOptions(command: command)

        #expect(options.mode == .printChoices)
        #expect(options.installation == "main")
        #expect(options.linearProjectID == "proj-1")
        #expect(options.projectID == nil)
    }

    @Test("printGitHubArguments parses back as --print-github with its Repos")
    func printGitHubParsesBack() throws {
        let built = SetupInvocation.printGitHubArguments(
            githubCredential: "keychain:github-work", repoPaths: ["~/dev/backend", "/srv/web"]
        )

        let options = try SetupOptions(command: try SetupCommand.parse(Array(built.dropFirst())))

        #expect(options.mode == .printGitHub)
        #expect(options.githubCredential == CredentialReference("keychain:github-work"))
        #expect(options.gitHubRepoPaths == ["~/dev/backend", "/srv/web"])
    }

    @Test("installGitHubArguments parses back as --install-github for each token source")
    func installGitHubParsesBack() throws {
        let stdin = SetupInvocation.installGitHubArguments(
            githubCredential: nil, source: .standardInput, replace: true, repoPaths: ["~/dev/backend"]
        )
        let fromGH = SetupInvocation.installGitHubArguments(
            githubCredential: "keychain:github", source: .githubCLI, replace: false, repoPaths: []
        )

        let stdinOptions = try SetupOptions(command: try SetupCommand.parse(Array(stdin.dropFirst())))
        let ghOptions = try SetupOptions(command: try SetupCommand.parse(Array(fromGH.dropFirst())))

        #expect(stdinOptions.mode == .installGitHub)
        #expect(stdinOptions.gitHubTokenSource == .standardInput)
        #expect(stdinOptions.replaceGitHubToken)
        #expect(stdinOptions.gitHubRepoPaths == ["~/dev/backend"])
        #expect(stdinOptions.githubCredential == nil)
        #expect(ghOptions.mode == .installGitHub)
        #expect(ghOptions.gitHubTokenSource == .githubCLI)
        #expect(!ghOptions.replaceGitHubToken)
        #expect(ghOptions.githubCredential == CredentialReference("keychain:github"))
    }
}
