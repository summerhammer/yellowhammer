import ArgumentParser
import Config
import Domain
@testable import EngineCommand
import Foundation
import Synchronization
import Testing

private let twoInstallations = """
    [board.linear.installations.alpha]
    credential = "keychain:linear-alpha"
    workspace = "ws-a"
    app_user = "app-a"
    operator = "user-op"

    [board.linear.installations.beta]
    credential = "keychain:linear-beta"
    workspace = "ws-b"
    app_user = "app-b"
    operator = "user-op"

    [github]
    credential = "keychain:github"
    """

private let oneInstallation = """
    [board.linear.installations.alpha]
    credential = "keychain:linear-alpha"
    workspace = "ws-a"
    app_user = "app-a"

    [github]
    credential = "keychain:github"
    """

private final class BoundNames: Sendable {
    private let storage = Mutex<[String]>([])
    var names: [String] { storage.withLock { $0 } }
    func record(_ name: String) { storage.withLock { $0.append(name) } }
}

private func runOperator(
    _ arguments: [String], directory: borrowing ConfigurationDirectory, board: FakeProvisioningBoard,
    bound: BoundNames = BoundNames()
) async throws -> (succeeded: Bool, lines: [String]) {
    let command = try #require(try ConfigOperatorCommand.parse(arguments) as? ConfigOperatorCommand)
    let output = RecordingOutput()
    do {
        try await command.run(
            configurationDirectory: directory.url, output: { output.record($0) },
            bindProvisioning: { installation, _ in
                bound.record(installation.name)
                return board
            }
        )
        return (true, output.lines)
    } catch {
        return (false, output.lines)
    }
}

@Suite("yh config operator")
struct ConfigOperatorCommandTests {
    @Test("Both config subcommands parse")
    func parses() throws {
        let parsed = try #require(
            try RootCommand.parseAsRoot(["config", "operator", "--installation", "a", "U1"]) as? ConfigOperatorCommand
        )
        #expect(parsed.installation == "a")
        #expect(parsed.userID == "U1")
        let removal = try #require(
            try RootCommand.parseAsRoot(["config", "remove-installation", "a"]) as? ConfigRemoveInstallationCommand
        )
        #expect(removal.name == "a")
    }

    @Test("No installation configured is refused, naming the connect command")
    func zeroInstallations() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("[github]\ncredential = \"keychain:github\"\n")
        let result = try await runOperator(["user-second"], directory: directory, board: await makeBoard())
        #expect(!result.succeeded)
        #expect(result.lines.joined().contains("yh setup --install-linear"))
    }

    @Test("Two installations without --installation is refused, listing the names; nothing is written")
    func ambiguous() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let bound = BoundNames()
        let result = try await runOperator(
            ["user-second"], directory: directory, board: await makeBoard(), bound: bound
        )
        #expect(!result.succeeded)
        let message = result.lines.joined()
        #expect(message.contains("alpha") && message.contains("beta") && message.contains("--installation is required"))
        #expect(try Data(contentsOf: file) == before)
        #expect(bound.names.isEmpty)
    }

    @Test("An --installation naming no entry is refused, naming it and the valid names")
    func unknownInstallation() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations)
        let result = try await runOperator(
            ["--installation", "gamma", "user-second"], directory: directory, board: await makeBoard()
        )
        #expect(!result.succeeded)
        let message = result.lines.joined()
        #expect(message.contains("gamma") && message.contains("alpha") && message.contains("beta"))
    }

    @Test(
        "A user id that is not a candidate is refused with setup's reason; nothing is written",
        arguments: [
            ("user-dead", "deactivated"), ("user-bot", "an app"), ("user-self", "Yellowhammer's own identity"),
            ("user-nobody", "not a workspace member")
        ]
    )
    func nonCandidate(id: String, reason: String) async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let board = await makeBoard(members: [operatorMember, deactivatedMember, appMember, selfMember])
        let result = try await runOperator(["--installation", "alpha", id], directory: directory, board: board)
        #expect(!result.succeeded)
        #expect(result.lines.joined().contains(reason))
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("Success rewrites only that installation's operator and leaves the sibling's")
    func rewritesOnlyThatEntry() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations)
        let bound = BoundNames()
        let board = await makeBoard(members: [operatorMember, secondCandidateMember])
        let result = try await runOperator(
            ["--installation", "beta", "user-second"], directory: directory, board: board, bound: bound
        )
        #expect(result.succeeded)
        #expect(bound.names == ["beta"])
        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.linearInstallation(named: "beta")?.operatorIdentity?.rawValue == "user-second")
        #expect(machine.linearInstallation(named: "alpha")?.operatorIdentity?.rawValue == "user-op")
        let message = result.lines.joined(separator: "\n")
        #expect(message.contains("beta") && message.contains("user-second"))
        #expect(message.contains("next Act") && message.contains("does not reassign"))
    }

    @Test("A single installation is used without the flag")
    func singleInstallationDefaults() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(oneInstallation)
        let board = await makeBoard(members: [operatorMember, secondCandidateMember])
        let result = try await runOperator(["user-second"], directory: directory, board: board)
        #expect(result.succeeded)
        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.linearInstallation(named: "alpha")?.operatorIdentity?.rawValue == "user-second")
    }

    @Test("A revoked installation maps to the re-connect failure; nothing is written")
    func notAuthenticated() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(oneInstallation)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let board = await makeBoard(members: [operatorMember])
        await board.refuseWorkspaceMembersNext(.notAuthenticated("revoked"))
        let result = try await runOperator(["user-op"], directory: directory, board: board)
        #expect(!result.succeeded)
        #expect(result.lines.joined().contains("yh setup --install-linear --installation alpha"))
        #expect(try Data(contentsOf: file) == before)
    }
}
