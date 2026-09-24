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
            linearClientID: "client-id",
            linearCredential: "keychain:linear",
            githubCredential: "keychain:github",
            cliAdapters: ["claude"],
            route: "claude/sonnet/medium",
            fallbacks: ["claude/opus/high"],
            operatorID: "user-op",
            passesSecretOnStandardInput: true,
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
        #expect(options.linearClientID == "client-id")
        #expect(options.linearCredential == CredentialReference("keychain:linear"))
        #expect(options.githubCredential == CredentialReference("keychain:github"))
        #expect(options.cliAdapters == [CLIAdapterDeclaration(name: "claude")])
        #expect(options.route?.route == Route(cli: "claude", model: "sonnet", effort: "medium"))
        #expect(options.route?.fallbacks ?? [] == [Route(cli: "claude", model: "opus", effort: "high")])
        #expect(options.operatorID == BoardObjectID(rawValue: "user-op"))
        #expect(options.linearClientSecretStdin == true)
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

    @Test("choicesArguments parses back as --print-choices, no Project or generating options") // glossary:ignore GL001
    func choicesArgumentsParsesBack() throws {
        let arguments = Array(SetupInvocation.choicesArguments(
            linearClientID: "client-id", linearCredential: "keychain:linear",
            githubCredential: "keychain:github", passesSecretOnStandardInput: true
        ).dropFirst())

        let command = try SetupCommand.parse(arguments)
        let options = try SetupOptions(command: command)

        #expect(options.mode == .printChoices)
        #expect(options.linearClientID == "client-id")
        #expect(options.linearCredential == CredentialReference("keychain:linear"))
        #expect(options.githubCredential == CredentialReference("keychain:github"))
        #expect(options.linearClientSecretStdin == true)
        #expect(options.projectID == nil)
    }
}
