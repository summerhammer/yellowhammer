import ArgumentParser
import Domain
import Engine
@testable import EngineCommand
import Foundation
import Testing

// OQ13: missing or uninitialized configuration exits with code 1 and points at `yh setup` or the app.
// OQ52(1): a LaunchAgent whose Project is absent or invalidated fails fast without running an Act.
// Each refusal is asserted through ArgumentParser's own mapping, which is what `yh` exits with and prints.

/// Parses `yh <act> --project <id>` and runs it against the given configuration directory.
private func runAct(
    _ act: Act,
    project: String,
    in directory: borrowing ConfigurationDirectory,
    force: Bool = false
) async throws {
    var args = [act.rawValue, "--project", project]
    if force {
        args.append("--force")
    }
    let parsed = try RootCommand.parseAsRoot(args)
    let command = try #require(parsed as? any ActCommand)
    // No Board bound: this suite is about configuration resolution, not the Night Card (NightCardTests).
    try await command.makeInvocation(configurationDirectory: directory.url, now: Date(), bindBoard: nil).run()
}

/// Runs the Act, requires it to be refused before it ran, and requires `yh` to exit with code 1.
/// Returns the refusal and the full message `yh` prints.
private func refusal(
    _ act: Act, project: String, in directory: borrowing ConfigurationDirectory
) async throws -> (ProjectResolutionError, message: String) {
    do {
        try await runAct(act, project: project, in: directory)
    } catch let error as ProjectResolutionError {
        #expect(RootCommand.exitCode(for: error) == ExitCode(1))
        return (error, RootCommand.fullMessage(for: error))
    }
    Issue.record("The Act was not refused")
    throw CancellationError()
}

@Test("A missing configuration directory refuses the Act with remediation", arguments: Act.allCases)
func missingConfigurationDirectory(_ act: Act) async throws {
    let directory = ConfigurationDirectory()

    let (error, message) = try await refusal(act, project: "yellowhammer", in: directory)

    #expect(error == .uninitialized(directory: directory.path))
    #expect(message.contains(directory.path))
    #expect(message.contains("No Act was run"))
    #expect(message.contains("`yh setup`"))
    #expect(message.contains("Yellowhammer.app"))
}

@Test("A configuration directory without config.toml is uninitialized", arguments: Act.allCases)
func missingMachineFile(_ act: Act) async throws {
    let directory = ConfigurationDirectory()
    try directory.createDirectory()
    try directory.writeValidProjectFile(id: "yellowhammer")

    let (error, message) = try await refusal(act, project: "yellowhammer", in: directory)

    #expect(error == .uninitialized(directory: directory.path))
    #expect(message.contains("`yh setup`"))
    #expect(message.contains("Yellowhammer.app"))
}

@Test("A malformed config.toml refuses the Act and names the error", arguments: Act.allCases)
func malformedMachineFile(_ act: Act) async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile(
        "[board.linear.connections.acme]\ncredential = \"keychain:linear\"\n"
            + "workspace = \"workspace-1\"\nyellowhammer_identity = \"app-user-1\"\n"
    )
    try directory.writeValidProjectFile(id: "yellowhammer")

    let (error, message) = try await refusal(act, project: "yellowhammer", in: directory)

    guard case .machineConfigurationInvalid(let cause) = error else {
        Issue.record("Expected an invalid machine-wide configuration, got \(error)")
        return
    }
    #expect(cause.reason == .missingTable)
    #expect(message.contains(cause.description))
    #expect(message.contains("No Act was run"))
    #expect(message.contains("`yh setup`"))
}

@Test("A --project with no Project file refuses the Act", arguments: Act.allCases)
func absentProject(_ act: Act) async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "yellowhammer")

    let (error, message) = try await refusal(act, project: "removed", in: directory)

    let expectedFile = directory.url.appending(components: "projects", "removed.toml").path(percentEncoded: false)
    #expect(error == .projectNotFound(id: "removed", expectedFile: expectedFile))
    #expect(message.contains("\"removed\""))
    #expect(message.contains(expectedFile))
    #expect(message.contains("No Act was run"))
    #expect(message.contains("`yh setup`"))
    #expect(message.contains("Yellowhammer.app"))
}

@Test("A --project with no Projects directory at all refuses the Act")
func absentProjectsDirectory() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()

    let (error, _) = try await refusal(.build, project: "yellowhammer", in: directory)

    guard case .projectNotFound(id: "yellowhammer", _) = error else {
        Issue.record("Expected an absent Project, got \(error)")
        return
    }
}

@Test("A --project that is not a valid Project id is an absent Project", arguments: ["../yellowhammer", "", "a b"])
func malformedProjectID(_ project: String) async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "yellowhammer")

    let (error, message) = try await refusal(.author, project: project, in: directory)

    guard case .projectNotFound(let id, _) = error else {
        Issue.record("Expected an absent Project, got \(error)")
        return
    }
    #expect(id == project)
    #expect(message.contains("No Act was run"))
}

@Test("An invalidated Project refuses the Act and lists every error", arguments: Act.allCases)
func invalidatedProject(_ act: Act) async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeProjectFile(id: "yellowhammer", """
        id = "yellowhammer"
        name = "Yellowhammer"
        board = { linear = { connection = "acme", project = "yellowhammer" } }

        [[repos]]
        name = "backend"
        path = "~/Developer/backend"
        role = "backend"
        check = "swift test"
        """)

    let (error, message) = try await refusal(act, project: "yellowhammer", in: directory)

    guard case .projectInvalidated(let id, _, let errors) = error else {
        Issue.record("Expected an invalidated Project, got \(error)")
        return
    }
    #expect(id.rawValue == "yellowhammer")
    #expect(errors.map(\.reason) == [.noSpecificationSource])
    #expect(message.contains("refused at load"))
    for error in errors {
        #expect(message.contains(error.description))
    }
    #expect(message.contains("No Act was run"))
}

@Test("A Project file that does not decode far enough to know its id is still matched by file")
func undecodableProject() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeProjectFile(id: "yellowhammer", "id = ")

    let (error, _) = try await refusal(.land, project: "yellowhammer", in: directory)

    guard case .projectInvalidated(let id, let file, _) = error else {
        Issue.record("Expected an invalidated Project, got \(error)")
        return
    }
    #expect(id.rawValue == "yellowhammer")
    #expect(file.hasSuffix("/yellowhammer.toml"))
}

@Test("An invalid Project file whose name merely ends with the id is not that Project")
func invalidProjectMatchedByWholeFileStem() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeProjectFile(id: "yellowhammer", "id = ")

    let (error, _) = try await refusal(.land, project: "hammer", in: directory)

    guard case .projectNotFound(id: "hammer", _) = error else {
        Issue.record("Expected an absent Project, got \(error)")
        return
    }
}

@Test("Two Projects sharing a working Repo are both refused; a third still runs its Act")
func workingRepoConflict() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha", repoPath: "~/Developer/shared")
    try directory.writeValidProjectFile(id: "beta", repoPath: "~/Developer/shared")
    try directory.writeValidProjectFile(id: "gamma")

    for project in ["alpha", "beta"] {
        let (error, message) = try await refusal(.build, project: project, in: directory)
        guard case .projectInvalidated(let id, _, _) = error else {
            Issue.record("Expected \(project) to be invalidated, got \(error)")
            continue
        }
        #expect(id.rawValue == project)
        #expect(message.contains("working Repo"))
    }
    // Force the Act because this test is about Repo conflict detection, not the trigger predicate. The
    // build Act now completes (no Feature in flight, so it does nothing) rather than throwing.
    try await runAct(.build, project: "gamma", in: directory, force: true)
}
