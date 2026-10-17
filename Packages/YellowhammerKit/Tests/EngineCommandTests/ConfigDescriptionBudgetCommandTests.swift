import ArgumentParser
import Domain
@testable import EngineCommand
import Foundation
import Testing

private let twoConnections = """
    [board.linear.connections.alpha]
    credential = "keychain:linear-alpha"
    workspace = "ws-a"
    yellowhammer_identity = "app-a"
    operator = "user-op"

    [board.linear.connections.beta]
    credential = "keychain:linear-beta"
    workspace = "ws-b"
    yellowhammer_identity = "app-b"
    description_budget = 5000

    [code_hosting.github.connections.github]
    type = "keychain"
    credential = "keychain:github"
    """

private func runBudget(
    _ arguments: [String], directory: borrowing ConfigurationDirectory
) throws -> (succeeded: Bool, lines: [String]) {
    let command = try #require(try ConfigDescriptionBudgetCommand.parse(arguments) as? ConfigDescriptionBudgetCommand)
    let output = RecordingOutput()
    do {
        try command.run(configurationDirectory: directory.url, output: { output.record($0) })
        return (true, output.lines)
    } catch {
        return (false, output.lines)
    }
}

@Suite("yh config description-budget")
struct ConfigDescriptionBudgetCommandTests {
    private let ceiling = ConfigDescriptionBudgetChange.ceiling

    @Test("The ceiling is 90% of Linear's 250,000-unit description limit")
    func ceilingIsNinetyPercent() {
        #expect(ceiling == 225_000)
    }

    @Test("It parses under yh config")
    func parses() throws {
        let parsed = try #require(
            try RootCommand.parseAsRoot(
                ["config", "description-budget", "--board-connection", "alpha", "12000"]
            ) as? ConfigDescriptionBudgetCommand
        )
        #expect(parsed.boardConnection == "alpha")
        #expect(parsed.budget == 12_000)
    }

    @Test("A valid value is written to that connection only, and everything else is unchanged")
    func writesOneConnection() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoConnections)
        let file = directory.url.appending(component: "config.toml")

        let result = try runBudget(["--board-connection", "alpha", "12000"], directory: directory)

        #expect(result.succeeded)
        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(after == twoConnections.replacingOccurrences(
            of: "operator = \"user-op\"", with: "operator = \"user-op\"\ndescription_budget = 12000"
        ))
        #expect(after.contains("description_budget = 5000"))
    }

    @Test("An existing value is replaced in place")
    func replacesExistingValue() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoConnections)

        let result = try runBudget(["--board-connection", "beta", "6000"], directory: directory)

        #expect(result.succeeded)
        let after = try String(contentsOf: directory.url.appending(component: "config.toml"), encoding: .utf8)
        #expect(after == twoConnections.replacingOccurrences(of: "= 5000", with: "= 6000"))
    }

    @Test("Exactly the ceiling is accepted")
    func acceptsTheCeiling() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoConnections)

        let result = try runBudget(["--board-connection", "alpha", "\(ceiling)"], directory: directory)

        #expect(result.succeeded)
        let after = try String(contentsOf: directory.url.appending(component: "config.toml"), encoding: .utf8)
        #expect(after.contains("description_budget = \(ceiling)"))
    }

    @Test("Zero and one above the ceiling are refused with a reason, and nothing is written")
    func refusesOutOfRange() throws {
        for value in [0, ceiling + 1] {
            let directory = ConfigurationDirectory()
            try directory.writeMachineFile(twoConnections)
            let file = directory.url.appending(component: "config.toml")
            let before = try Data(contentsOf: file)

            let result = try runBudget(["--board-connection", "alpha", "\(value)"], directory: directory)

            #expect(!result.succeeded)
            let message = result.lines.joined()
            #expect(message.contains("description_budget"), "\(value)")
            #expect(value == 0 ? message.contains(">= 1") : message.contains("at most \(ceiling)"), "\(value)")
            #expect(try Data(contentsOf: file) == before)
        }
    }

    @Test("A Board Connection that is not configured is refused, naming the valid ones; nothing is written")
    func refusesUnknownConnection() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoConnections)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)

        let result = try runBudget(["--board-connection", "gamma", "12000"], directory: directory)

        #expect(!result.succeeded)
        let message = result.lines.joined()
        #expect(message.contains("gamma") && message.contains("alpha") && message.contains("beta"))
        #expect(try Data(contentsOf: file) == before)
    }
}
