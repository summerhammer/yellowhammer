import ArgumentParser
import Domain
@testable import EngineCommand
import Testing

/// Feeds ``ProjectInvocation``'s built argument vector back through the real `yh project` parser, so the
/// app's argument-building contract and the command's flag spelling can never silently drift apart.
@Suite("ProjectInvocation ↔ yh project contract") // glossary:ignore GL001
struct ProjectInvocationContractTests {
    @Test("removeArguments parses back as ProjectRemoveCommand with --yes")
    func removeArgumentsParseBack() throws {
        let id = try #require(ProjectID(rawValue: "acme-web"))
        let arguments = ProjectInvocation.removeArguments(project: id)

        let parsed = try ProjectCommand.parseAsRoot(Array(arguments.dropFirst()))

        let command = try #require(parsed as? ProjectRemoveCommand)
        #expect(command.id == "acme-web")
        #expect(command.yes)
    }
}
