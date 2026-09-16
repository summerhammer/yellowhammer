import ArgumentParser
import Domain
import Engine
@testable import EngineCommand
import Foundation
import Journal
import Testing

// P4.1: Command surface for the Acts
// Three Operator gestures: Force an Act, Force authoring, Run a rehearsal Night.

private func runAct(
    _ act: Act,
    project: String,
    arguments: [String] = [],
    in directory: borrowing ConfigurationDirectory
) async throws {
    var argv = [act.rawValue, "--project", project]
    argv.append(contentsOf: arguments)
    let parsed = try RootCommand.parseAsRoot(argv)
    let command = try #require(parsed as? any ActCommand)
    try await command.run(configurationDirectory: directory.url)
}

private func makeInvocationInDirectory(
    _ act: Act,
    project: String,
    arguments: [String] = [],
    in directory: borrowing ConfigurationDirectory
) throws -> EngineInvocation {
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: project)
    var argv = [act.rawValue, "--project", project]
    argv.append(contentsOf: arguments)
    let parsed = try RootCommand.parseAsRoot(argv)
    let command = try #require(parsed as? any ActCommand)
    return try command.makeInvocation(configurationDirectory: directory.url)
}

// MARK: Default behavior

@Test("Default: no flags → trigger == .scheduled and mode == .real")
func defaultNoFlagsScheduledReal() throws {
    let directory = ConfigurationDirectory()
    let invocation = try makeInvocationInDirectory(.author, project: "alpha", in: directory)

    #expect(invocation.trigger == .scheduled)
    #expect(invocation.mode == .real)
}

// MARK: - -force flag

@Test("--force on each Act → trigger == .forced", arguments: Act.allCases)
func forceFlag(_ act: Act) throws {
    let directory = ConfigurationDirectory()
    let invocation = try makeInvocationInDirectory(
        act,
        project: "alpha",
        arguments: ["--force"],
        in: directory
    )

    #expect(invocation.trigger == .forced)
}

// MARK: - -rehearsal flag

@Test("--rehearsal on each Act → mode == .rehearsal, trigger == .scheduled", arguments: Act.allCases)
func rehearsalFlag(_ act: Act) throws {
    let directory = ConfigurationDirectory()
    let invocation = try makeInvocationInDirectory(
        act,
        project: "alpha",
        arguments: ["--rehearsal"],
        in: directory
    )

    #expect(invocation.mode == .rehearsal)
    #expect(invocation.trigger == .scheduled)
}

// MARK: - -force and --rehearsal together

@Test("--force --rehearsal together → both set")
func forceAndRehearsalTogether() throws {
    let directory = ConfigurationDirectory()
    let invocation = try makeInvocationInDirectory(
        .author,
        project: "alpha",
        arguments: ["--force", "--rehearsal"],
        in: directory
    )

    #expect(invocation.trigger == .forced)
    #expect(invocation.mode == .rehearsal)
}

// MARK: - -feature flag

@Test("yh author --feature \"Ship the Journal\" → forcedForFeature with that name")
func featureFlag() throws {
    let directory = ConfigurationDirectory()
    let invocation = try makeInvocationInDirectory(
        .author,
        project: "alpha",
        arguments: ["--feature", "Ship the Journal"],
        in: directory
    )

    guard case .forcedForFeature(let name) = invocation.trigger else {
        Issue.record("Expected forcedForFeature trigger")
        return
    }
    #expect(name.rawValue == "Ship the Journal")
    #expect(invocation.trigger.isForced)
}

@Test("yh author --feature with spaced input → trimmed")
func featureFlagTrimmed() throws {
    let directory = ConfigurationDirectory()
    let invocation = try makeInvocationInDirectory(
        .author,
        project: "alpha",
        arguments: ["--feature", "  spaced  "],
        in: directory
    )

    guard case .forcedForFeature(let name) = invocation.trigger else {
        Issue.record("Expected forcedForFeature trigger")
        return
    }
    #expect(name.rawValue == "spaced")
}

@Test("yh author --feature with empty string → validate() throws", arguments: ["", "   ", "\n"])
func featureFlagEmpty(_ input: String) {
    #expect(throws: (any Error).self) {
        _ = try RootCommand.parseAsRoot(["author", "--project", "alpha", "--feature", input])
    }
}

// MARK: - -feature not on build or land

@Test("yh build --feature X → fails to parse")
func featureFlagBuildFails() {
    #expect(throws: (any Error).self) {
        try RootCommand.parseAsRoot(["build", "--project", "alpha", "--feature", "X"])
    }
}

@Test("yh land --feature X → fails to parse")
func featureFlagLandFails() {
    #expect(throws: (any Error).self) {
        try RootCommand.parseAsRoot(["land", "--project", "alpha", "--feature", "X"])
    }
}

// MARK: Flag spellings are a contract

@Test("Flag --force appears in help text")
func forceFlagInHelp() {
    let help = AuthorCommand.helpMessage()
    #expect(help.contains("--force"))
}

@Test("Flag --rehearsal appears in help text")
func rehearsalFlagInHelp() {
    let help = AuthorCommand.helpMessage()
    #expect(help.contains("--rehearsal"))
}

@Test("Flag --feature appears in help text for author")
func featureFlagInHelp() {
    let help = AuthorCommand.helpMessage()
    #expect(help.contains("--feature"))
}

// MARK: Error cases

@Test("forcedForFeature on build Act → featureNamedForNonAuthoringAct error, no lease taken")
func featureNamedForNonAuthoringActBuild() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))
    let journal = try JournalStore.open(configurationDirectory: directory.url, projectID: projectID)

    let invocation = EngineInvocation(
        act: .build,
        mode: .real,
        journal: journal,
        trigger: .forcedForFeature(try #require(FeatureName(rawValue: "test")))
    )

    await #expect(throws: EngineInvocationError.featureNamedForNonAuthoringAct(.build)) {
        try await invocation.run()
    }

    let events = try journal.events()
    #expect(events.isEmpty)
}

@Test("forcedForFeature on land Act → featureNamedForNonAuthoringAct error, no lease taken")
func featureNamedForNonAuthoringActLand() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))
    let journal = try JournalStore.open(configurationDirectory: directory.url, projectID: projectID)

    let invocation = EngineInvocation(
        act: .land,
        mode: .real,
        journal: journal,
        trigger: .forcedForFeature(try #require(FeatureName(rawValue: "test")))
    )

    await #expect(throws: EngineInvocationError.featureNamedForNonAuthoringAct(.land)) {
        try await invocation.run()
    }

    let events = try journal.events()
    #expect(events.isEmpty)
}

// MARK: Project resolution is not bypassed

@Test("--force --rehearsal with missing config → still fails with uninitialized error", arguments: Act.allCases)
func forceFlagsDoNotBypassProjectResolution(_ act: Act) async throws {
    let directory = ConfigurationDirectory()

    await #expect(throws: ProjectResolutionError.self) {
        try await runAct(act, project: "missing", arguments: ["--force", "--rehearsal"], in: directory)
    }
}

@Test("yh author --feature with missing config → still fails with uninitialized error")
func featureFlagDoesNotBypassProjectResolution() async throws {
    let directory = ConfigurationDirectory()

    await #expect(throws: ProjectResolutionError.self) {
        try await runAct(.author, project: "missing", arguments: ["--feature", "Test"], in: directory)
    }
}
