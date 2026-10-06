import ArgumentParser
import Domain
import Engine
@testable import EngineCommand
import Foundation
import Journal
import Testing

@Test("The command is named yh")
func rootCommandIsNamedYh() {
    #expect(RootCommand.configuration.commandName == "yh")
}

// These words are typed into Orca ADE Automations by hand, so their spelling and order are a contract.
@Test("Subcommands: Acts, probe, setup, doctor, validate, status, project, recalibrate, rehearse, stop, abort, config")
func subcommandsAreTheActsInOrder() {
    let names = RootCommand.configuration.subcommands.map { $0.configuration.commandName }
    #expect(names == Act.allCases.map(\.rawValue) + [
        "probe", "setup", "doctor", "validate", "status", "project", "recalibrate", "rehearse", "stop", "abort",
        "config"
    ])
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

@Test("An Act invocation creates the Project's Journal with its Board Connection's Linear workspace")
func actInvocationRecordsInstallationWorkspace() throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile(
        ConfigurationDirectory.machineFile.replacingOccurrences(of: "workspace-1", with: "workspace-z")
    )
    try directory.writeValidProjectFile(id: "yellowhammer")
    let projectID = try #require(ProjectID(rawValue: "yellowhammer"))
    let fileURL = JournalStore.defaultFileURL(configurationDirectory: directory.url, id: projectID)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))

    let parsed = try RootCommand.parseAsRoot(["author", "--project", "yellowhammer"])
    let command = try #require(parsed as? any ActCommand)
    _ = try command.makeInvocation(configurationDirectory: directory.url, now: Date(), bindBoard: nil)

    let journal = try JournalStore.openReadOnly(at: fileURL, projectID: projectID)
    #expect(journal.linearWorkspace == BoardObjectID(rawValue: "workspace-z"))
}
