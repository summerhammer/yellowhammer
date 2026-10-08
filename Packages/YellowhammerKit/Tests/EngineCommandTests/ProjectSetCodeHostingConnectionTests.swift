import ArgumentParser
import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

@Suite("yh project set-code-hosting-connection")
struct ProjectSetCodeHostingConnectionTests {
    private static let machineWithWork = ConfigurationDirectory.machineFile + """


        [code_hosting.github.connections.work]
        type = "keychain"
        credential = "keychain:github-work"

        [code_hosting.github.connections.gh]
        type = "gh"
        """

    private static func credentials() -> RecordingCredentialStore {
        RecordingCredentialStore(seed: [
            "keychain:linear": "test-linear",
            "keychain:github": "ghp_default",
            "keychain:github-work": "ghp_work"
        ])
    }

    private func writeProject(
        _ directory: borrowing ConfigurationDirectory, id: String,
        repos: [(name: String, role: String)] = [("backend", "backend")], connection: String = "github"
    ) throws {
        let specSource = repos.contains { $0.role == "spec" } ? "" : "spec_source = \"~/Developer/\(id)-spec\"\n"
        let declarations = repos.map {
            """

            [[repos]]
            name = "\($0.name)"
            path = "~/dev/\(id)-\($0.name)"
            role = "\($0.role)"
            check = "swift test"
            """
        }.joined()
        try directory.writeProjectFile(id: id, """
            id = "\(id)"
            name = "\(id)"
            board = { linear = { connection = "acme", project = "\(id)" } }
            code_hosting = { connection = "\(connection)" }
            \(specSource)\(declarations)
            """)
    }

    @Test("Push check passes: saves selection to Project file, preserving existing content")
    func changeSavedWhenCheckPasses() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machineWithWork)
        try writeProject(directory, id: "alpha", connection: "github")
        let transport = StubGitHubTransport.passing()
        let output = RecordingOutput()

        let command = try ProjectSetCodeHostingConnectionCommand.parse(["alpha", "work"])
        try await command.run(
            configurationDirectory: directory.url,
            credentials: Self.credentials(),
            gitHub: transport.validation(),
            output: output.record
        )

        let projectFile = directory.url.appending(components: "projects", "alpha.toml")
        let text = try String(contentsOf: projectFile, encoding: .utf8)
        #expect(text.contains("code_hosting = { connection = \"work\" }"))
        let parsed = try ProjectConfiguration.load(contentsOf: projectFile)
        #expect(parsed.codeHostingConnectionName == "work")
        #expect(output.lines.contains { $0.contains("Code Hosting Connection for Project alpha set to work.") })
    }

    @Test("Push check refuses change: SetupError is thrown and Project file is untouched")
    func pushCheckRefusesAndNothingWritten() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machineWithWork)
        try writeProject(directory, id: "alpha", repos: [("backend", "backend")], connection: "github")
        let transport = StubGitHubTransport.passing(routes: ["/repos/acme/alpha-backend": .repo(push: false)])
        let output = RecordingOutput()

        let command = try ProjectSetCodeHostingConnectionCommand.parse(["alpha", "work"])

        await #expect(throws: SetupError.self) {
            try await command.run(
                configurationDirectory: directory.url,
                credentials: Self.credentials(),
                gitHub: transport.validation(),
                output: output.record
            )
        }

        let projectFile = directory.url.appending(components: "projects", "alpha.toml")
        let text = try String(contentsOf: projectFile, encoding: .utf8)
        #expect(text.contains("code_hosting = { connection = \"github\" }"))
        let parsed = try ProjectConfiguration.load(contentsOf: projectFile)
        #expect(parsed.codeHostingConnectionName == "github")
    }

    @Test("Spec-role Repo is skipped during push check")
    func specRepoSkipped() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machineWithWork)
        try writeProject(
            directory, id: "alpha",
            repos: [("backend", "backend"), ("spec", "spec")],
            connection: "github"
        )
        let transport = StubGitHubTransport.passing(routes: ["/repos/acme/alpha-spec": .repo(push: false)])
        let output = RecordingOutput()

        let command = try ProjectSetCodeHostingConnectionCommand.parse(["alpha", "work"])
        try await command.run(
            configurationDirectory: directory.url,
            credentials: Self.credentials(),
            gitHub: transport.validation(),
            output: output.record
        )

        let projectFile = directory.url.appending(components: "projects", "alpha.toml")
        let parsed = try ProjectConfiguration.load(contentsOf: projectFile)
        #expect(parsed.codeHostingConnectionName == "work")
        #expect(!transport.paths.contains("/repos/acme/alpha-spec"))
    }

    @Test("Fine-grained token whose push right cannot be verified is reported as unverified, and change is saved")
    func fineGrainedTokenReportedUnverifiedAndSaved() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machineWithWork)
        try writeProject(directory, id: "alpha", connection: "github")
        let transport = StubGitHubTransport.passing(routes: ["/user": .user(scopes: nil)])
        let output = RecordingOutput()

        let command = try ProjectSetCodeHostingConnectionCommand.parse(["alpha", "work"])
        try await command.run(
            configurationDirectory: directory.url,
            credentials: Self.credentials(),
            gitHub: transport.validation(),
            output: output.record
        )

        let projectFile = directory.url.appending(components: "projects", "alpha.toml")
        let parsed = try ProjectConfiguration.load(contentsOf: projectFile)
        #expect(parsed.codeHostingConnectionName == "work")
        #expect(output.lines.contains { $0.contains("cannot be confirmed without writing") })
        #expect(output.lines.contains { $0.contains("Code Hosting Connection for Project alpha set to work.") })
    }

    @Test("Refuses gh CLI connection with explanatory description")
    func refusesGHCLIConnection() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machineWithWork)
        try writeProject(directory, id: "alpha", connection: "github")
        let transport = StubGitHubTransport.passing()
        let output = RecordingOutput()

        let command = try ProjectSetCodeHostingConnectionCommand.parse(["alpha", "gh"])

        do {
            try await command.run(
                configurationDirectory: directory.url,
                credentials: Self.credentials(),
                gitHub: transport.validation(),
                output: output.record
            )
            Issue.record("expected refusal")
        } catch let error as SetupError {
            #expect(error.message.contains("uses the gh CLI, which this build of Yellowhammer cannot use yet"))
        }

        let projectFile = directory.url.appending(components: "projects", "alpha.toml")
        let parsed = try ProjectConfiguration.load(contentsOf: projectFile)
        #expect(parsed.codeHostingConnectionName == "github")
    }

    @Test("Refuses unknown connection and lists connected ones")
    func refusesUnknownConnection() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machineWithWork)
        try writeProject(directory, id: "alpha", connection: "github")
        let transport = StubGitHubTransport.passing()
        let output = RecordingOutput()

        let command = try ProjectSetCodeHostingConnectionCommand.parse(["alpha", "nonexistent"])

        do {
            try await command.run(
                configurationDirectory: directory.url,
                credentials: Self.credentials(),
                gitHub: transport.validation(),
                output: output.record
            )
            Issue.record("expected refusal")
        } catch let error as SetupError {
            #expect(error.message.contains("nonexistent is not a connected Code Hosting Connection"))
            #expect(error.message.contains("connected: github, work, gh"))
        }
    }

    @Test("Refuses unknown Project")
    func refusesUnknownProject() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machineWithWork)
        let transport = StubGitHubTransport.passing()
        let output = RecordingOutput()

        let command = try ProjectSetCodeHostingConnectionCommand.parse(["missing", "work"])

        await #expect(throws: SetupError.self) {
            try await command.run(
                configurationDirectory: directory.url,
                credentials: Self.credentials(),
                gitHub: transport.validation(),
                output: output.record
            )
        }
    }

    @Test("Command parses options and aliases under yh project")
    func parsesOptionsAndAliases() throws {
        let withOptions = try ProjectSetCodeHostingConnectionCommand.parse([
            "--project", "alpha", "--connection", "work"
        ])
        try withOptions.validate()
        #expect(withOptions.projectOption == "alpha")
        #expect(withOptions.connectionOption == "work")

        let underProject = try ProjectCommand.parseAsRoot(["set-code-hosting-connection", "alpha", "work"])
        #expect(underProject is ProjectSetCodeHostingConnectionCommand)

        let aliasSelect = try ProjectCommand.parseAsRoot(["select-code-hosting-connection", "alpha", "work"])
        #expect(aliasSelect is ProjectSetCodeHostingConnectionCommand)

        let aliasShort = try ProjectCommand.parseAsRoot(["set-code-hosting", "alpha", "work"])
        #expect(aliasShort is ProjectSetCodeHostingConnectionCommand)
    }
}
