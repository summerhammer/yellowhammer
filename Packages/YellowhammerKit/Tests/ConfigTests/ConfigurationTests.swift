import Config
import Domain
import Foundation
import Testing

/// The fixture matrix for load-time validation with per-Project failure isolation (P2.3). Each
/// scenario is a directory holding a `config.toml` and a `projects/` directory.
private func set(_ scenario: String) throws -> URL {
    try #require(Bundle.module.url(forResource: "Sets/\(scenario)", withExtension: nil, subdirectory: "Fixtures"))
}

private func projectFile(_ scenario: String, _ id: String) throws -> String {
    try set(scenario).appending(components: "projects", "\(id).toml").path(percentEncoded: false)
}

private func projectID(_ string: String) throws -> ProjectID {
    try #require(ProjectID(rawValue: string))
}

@Test("The default directory is ~/.config/yellowhammer")
func defaultDirectoryURL() {
    let home = URL(filePath: "/Users/operator", directoryHint: .isDirectory)
    let url = Configuration.defaultDirectoryURL(homeDirectory: home)
    #expect(url.path(percentEncoded: false) == "/Users/operator/.config/yellowhammer/")
}

@Test("Two Projects declaring the same working Repo are both refused; the third Project loads")
func workingRepoExclusivityRefusesBothAndSparesTheSibling() throws {
    let configuration = try Configuration.load(directory: set("exclusivity"))

    #expect(configuration.projects.map(\.id) == [try projectID("gamma")])
    #expect(configuration.machine.cliAdapters.map(\.name) == ["claude", "codex"])

    let alphaFile = try projectFile("exclusivity", "alpha")
    let betaFile = try projectFile("exclusivity", "beta")
    let expected = [
        InvalidProject(
            file: alphaFile,
            id: try projectID("alpha"),
            errors: [
                ConfigurationError(
                    file: alphaFile, line: 8, key: "repos[0].path",
                    reason: .workingRepoConflict(project: try projectID("beta"), file: betaFile)
                )
            ]
        ),
        InvalidProject(
            file: betaFile,
            id: try projectID("beta"),
            errors: [
                ConfigurationError(
                    file: betaFile, line: 14, key: "repos[1].path",
                    reason: .workingRepoConflict(project: try projectID("alpha"), file: alphaFile)
                )
            ]
        )
    ]
    #expect(configuration.invalidProjects == expected)
}

@Test("A Spec Source may be shared, including with the Project that writes the same repository")
func sharedSpecSourceIsNotAConflict() throws {
    let configuration = try Configuration.load(directory: set("shared-spec-source"))
    #expect(configuration.invalidProjects.isEmpty)
    let expectedIDs = [try projectID("owner"), try projectID("reader"), try projectID("reader2")]
    #expect(configuration.projects.map(\.id) == expectedIDs)
}

@Test("A Routing Table override naming a CLI with no adapter refuses that Project only")
func overrideWithUndeclaredAdapterRefusesOneProject() throws {
    let configuration = try Configuration.load(directory: set("override-undeclared-cli"))
    #expect(configuration.projects.map(\.id) == [try projectID("good")])

    let badFile = try projectFile("override-undeclared-cli", "bad")
    #expect(configuration.invalidProjects == [
        InvalidProject(
            file: badFile,
            id: nil,
            errors: [
                ConfigurationError(
                    file: badFile, line: 14, key: "routing[0].route", reason: .undeclaredCLIAdapter("gemini")
                )
            ]
        )
    ])
}

@Test("A Project file that does not parse is refused on its own")
func unparsableProjectFileIsIsolated() throws {
    let configuration = try Configuration.load(directory: set("unparsable-sibling"))
    #expect(configuration.projects.map(\.id) == [try projectID("fine")])

    let invalid = try #require(configuration.invalidProjects.first)
    #expect(configuration.invalidProjects.count == 1)
    #expect(invalid.file == (try projectFile("unparsable-sibling", "broken")))
    #expect(invalid.id == nil)
    #expect(invalid.errors.count == 1)
    #expect(invalid.errors.first?.line == 2)
}

@Test("Without a projects directory the machine-wide file loads alone")
func noProjectsDirectoryLoadsNoProjects() throws {
    let configuration = try Configuration.load(directory: set("no-projects-directory"))
    #expect(configuration.projects.isEmpty)
    #expect(configuration.invalidProjects.isEmpty)
}

@Test("A directory without config.toml is not set up, even with a projects directory")
func missingMachineFileIsNotSetUp() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yellowhammer-not-set-up-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(try Configuration.loadIfSetUp(directory: directory) == nil)

    try FileManager.default.createDirectory(
        at: directory.appending(component: "projects", directoryHint: .isDirectory),
        withIntermediateDirectories: true
    )
    #expect(try Configuration.loadIfSetUp(directory: directory) == nil)
}

@Test("A directory with config.toml loads as it would through load(directory:)")
func presentMachineFileLoadsIfSetUp() throws {
    let configuration = try #require(try Configuration.loadIfSetUp(directory: set("no-projects-directory")))
    #expect(configuration.projects.isEmpty)
}

@Test("A config.toml that exists but does not load still fails, never reads as not set up")
func invalidMachineFileFailsLoadIfSetUp() throws {
    let directory = try set("machine-invalid")
    let result = Result { () throws(ConfigurationError) in try Configuration.loadIfSetUp(directory: directory) }
    guard case .failure(let error) = result else {
        Issue.record("expected the load to fail")
        return
    }
    #expect(error.reason == .missingTable)
}

@Test("A machine-wide file that does not load fails the whole load")
func invalidMachineFileFailsTheLoad() throws {
    let directory = try set("machine-invalid")
    let result = Result { () throws(ConfigurationError) in try Configuration.load(directory: directory) }
    guard case .failure(let error) = result else {
        Issue.record("expected the load to fail")
        return
    }
    #expect(error.key == "github")
    #expect(error.reason == .missingTable)
}

@Test("Every error names its file, line, key and the other Project when it prints")
func conflictErrorPrints() throws {
    let error = ConfigurationError(
        file: "/cfg/projects/alpha.toml", line: 8, key: "repos[0].path",
        reason: .workingRepoConflict(project: try projectID("beta"), file: "/cfg/projects/beta.toml")
    )
    #expect(
        error.description
            == "/cfg/projects/alpha.toml:8: repos[0].path: repository is also declared as a working Repo "
            + "by Project \"beta\" (/cfg/projects/beta.toml)"
    )
}

@Test("A Project naming an installation missing from the registry is refused alone; its sibling loads")
func undeclaredInstallationRefusesOneProject() throws {
    let configuration = try Configuration.load(directory: set("undeclared-installation"))
    #expect(configuration.projects.map(\.id) == [try projectID("good")])
    #expect(configuration.machine.linearInstallations.map(\.name) == ["acme"])

    let good = try #require(configuration.projects.first)
    #expect(configuration.machine.linearInstallation(for: good)?.name == "acme")

    let badFile = try projectFile("undeclared-installation", "bad")
    #expect(configuration.invalidProjects == [
        InvalidProject(
            file: badFile,
            id: nil,
            errors: [
                ConfigurationError(
                    file: badFile, line: 6, key: "board.linear.installation",
                    reason: .undeclaredLinearInstallation("missing")
                )
            ]
        )
    ])
}

@Test("The lenient removal load accepts an installation missing from the registry")
func lenientLoadAcceptsUndeclaredInstallation() throws {
    let configuration = try Configuration.loadLeniently(directory: set("undeclared-installation"))
    #expect(configuration.projects.map(\.id.rawValue) == ["bad", "good"])
    #expect(configuration.invalidProjects.isEmpty)
    let bad = try #require(configuration.projects.first)
    #expect(bad.linearInstallationName == "missing")
    #expect(configuration.machine.linearInstallation(for: bad) == nil)
}

@Test("The lenient removal load still refuses a Project with no installation key")
func lenientLoadRefusesMissingInstallationKey() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-lenient-\(UUID().uuidString)", directoryHint: .isDirectory)
    let projects = directory.appending(component: "projects", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let machineFile = try set("undeclared-installation").appending(component: "config.toml")
    let machine = try String(contentsOf: machineFile, encoding: .utf8)
    try machine.write(to: directory.appending(component: "config.toml"), atomically: true, encoding: .utf8)
    let project = """
        id = "keyless"
        name = "Keyless"
        spec_source = "~/spec"

        [board.linear]
        project = "KL"

        [[repos]]
        name = "r"
        path = "~/keyless"
        role = "backend"
        check = "none"
        """
    try project.write(to: projects.appending(component: "keyless.toml"), atomically: true, encoding: .utf8)

    let configuration = try Configuration.loadLeniently(directory: directory)
    #expect(configuration.projects.isEmpty)
    let error = try #require(configuration.invalidProjects.first?.errors.first)
    #expect(error.key == "board.linear.installation")
    #expect(error.reason == .missingKey)
}
