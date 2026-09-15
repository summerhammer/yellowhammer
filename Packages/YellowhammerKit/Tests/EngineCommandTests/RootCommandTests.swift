import ArgumentParser
import Domain
import Engine
@testable import EngineCommand
import Testing

@Test("The command is named yh")
func rootCommandIsNamedYh() {
    #expect(RootCommand.configuration.commandName == "yh")
}

// These words are typed into Orca ADE Automations by hand, so their spelling and order are a contract.
@Test("Subcommands are exactly the Acts, in Act order")
func subcommandsAreTheActsInOrder() {
    let names = RootCommand.configuration.subcommands.map { $0.configuration.commandName }
    #expect(names == Act.allCases.map(\.rawValue))
}

@Test("Each subcommand parses and runs its own Act for a configured Project", arguments: Act.allCases)
func subcommandRunsItsAct(_ act: Act) async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "yellowhammer")
    let parsed = try RootCommand.parseAsRoot([act.rawValue, "--project", "yellowhammer"])
    let command = try #require(parsed as? any ActCommand)
    await #expect(throws: EngineInvocationError.notImplemented(act)) {
        try await command.run(configurationDirectory: directory.url)
    }
}

@Test("An unknown subcommand fails to parse")
func unknownSubcommandFailsToParse() {
    #expect(throws: (any Error).self) {
        try RootCommand.parseAsRoot(["deploy"])
    }
}

@Test("An Act without --project fails to parse", arguments: Act.allCases)
func actWithoutProjectFailsToParse(_ act: Act) {
    #expect(throws: (any Error).self) {
        try RootCommand.parseAsRoot([act.rawValue])
    }
}
