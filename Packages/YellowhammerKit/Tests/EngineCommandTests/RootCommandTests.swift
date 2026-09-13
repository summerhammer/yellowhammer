import ArgumentParser
import Domain
import Engine
import EngineCommand
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

@Test("Each subcommand parses and runs its own Act", arguments: Act.allCases)
func subcommandRunsItsAct(_ act: Act) async throws {
    var command = try #require(try RootCommand.parseAsRoot([act.rawValue]) as? any AsyncParsableCommand)
    await #expect(throws: EngineInvocationError.notImplemented(act)) {
        try await command.run()
    }
}

@Test("An unknown subcommand fails to parse")
func unknownSubcommandFailsToParse() {
    #expect(throws: (any Error).self) {
        try RootCommand.parseAsRoot(["deploy"])
    }
}
