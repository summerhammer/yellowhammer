import ArgumentParser
import Domain
@testable import EngineCommand
import Testing

/// Feeds ``ConfigInvocation``'s built argument vectors back through the real `yh config` parsers, so the
/// app's argument-building contract and the commands' flag spelling can never silently drift apart.
@Suite("ConfigInvocation ↔ yh config contract")
struct ConfigInvocationContractTests {
    @Test("operatorArguments parses back as ConfigOperatorCommand")
    func operatorArgumentsParseBack() throws {
        let arguments = ConfigInvocation.operatorArguments(boardConnection: "acme", userID: "user-1")

        let parsed = try ConfigCommand.parseAsRoot(Array(arguments.dropFirst()))

        let command = try #require(parsed as? ConfigOperatorCommand)
        #expect(command.boardConnection == "acme")
        #expect(command.userID == "user-1")
    }

    @Test("removeBoardConnectionArguments parses back as ConfigRemoveBoardConnectionCommand")
    func removeInstallationArgumentsParseBack() throws {
        let arguments = ConfigInvocation.removeBoardConnectionArguments(name: "acme")

        let parsed = try ConfigCommand.parseAsRoot(Array(arguments.dropFirst()))

        let command = try #require(parsed as? ConfigRemoveBoardConnectionCommand)
        #expect(command.name == "acme")
    }

    @Test("removeBoardConnectionArguments with orphanProjects parses back with both flags")
    func removeInstallationOrphanParsesBack() throws {
        let arguments = ConfigInvocation.removeBoardConnectionArguments(name: "acme", orphanProjects: true)

        let parsed = try ConfigCommand.parseAsRoot(Array(arguments.dropFirst()))

        let command = try #require(parsed as? ConfigRemoveBoardConnectionCommand)
        #expect(command.name == "acme")
        #expect(command.orphanProjects)
        #expect(command.yes)
    }
}
