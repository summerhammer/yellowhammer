import ArgumentParser
import Domain
import Engine
@testable import EngineCommand
import Foundation
import Testing

@Test("The command is named yh")
func rootCommandIsNamedYh() {
    #expect(RootCommand.configuration.commandName == "yh")
}

// These words are typed into Orca ADE Automations by hand, so their spelling and order are a contract.
@Test("Subcommands are exactly the Acts, in Act order, followed by the Operator-invoked probe")
func subcommandsAreTheActsInOrder() {
    let names = RootCommand.configuration.subcommands.map { $0.configuration.commandName }
    #expect(names == Act.allCases.map(\.rawValue) + ["probe"])
}

@Test("Each subcommand parses and runs its own Act for a configured Project", arguments: Act.allCases)
func subcommandRunsItsAct(_ act: Act) async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "yellowhammer")
    var args = [act.rawValue, "--project", "yellowhammer"]
    // This test is about CLI parsing and dispatch, not the trigger predicate. On an empty Journal
    // the author trigger is met on its own; build and land need the Operator's force gesture to
    // reach the Act's work at all.
    if act != .author {
        args.append("--force")
    }
    let parsed = try RootCommand.parseAsRoot(args)
    let command = try #require(parsed as? any ActCommand)
    // No Board bound: this test is about CLI dispatch, not the Night Card (NightCardTests). Every Act's
    // work has landed (P8.1, P9.11, P10.1): on an empty Journal each completes doing nothing rather than
    // throwing.
    try await command.makeInvocation(configurationDirectory: directory.url, now: Date(), bindBoard: nil).run()
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
