import Config
import Domain
@testable import EngineCommand
import Foundation
import Synchronization
import Testing

private struct NoSetupPrompts: SetupConsole {
    func ask(_ prompt: String) -> String? {
        Issue.record("Unexpected setup prompt: \(prompt)")
        return nil
    }
}

@Suite("yh setup, saved configuration for scheduled jobs")
struct SetupSavedJobsTests {
    @Test("Bare job installation reuses saved connections and does not rewrite configuration",
           arguments: [true, false])
    func installSavedJobs(isTTY: Bool) async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(ConfigurationDirectory.machineFile + """

            [board.linear.connections.other]
            credential = "keychain:linear-other"
            workspace = "workspace-other"
            yellowhammer_identity = "app-other"

            [code_hosting.github.connections.other]
            type = "keychain"
            credential = "keychain:github-other"
            """)
        try directory.writeValidProjectFile(id: "alpha")
        try directory.writeValidProjectFile(id: "beta")
        let betaURL = directory.url.appending(components: "projects", "beta.toml")
        let betaText = try String(contentsOf: betaURL, encoding: .utf8)
            .replacingOccurrences(of: "connection = \"acme\"", with: "connection = \"other\"")
            .replacingOccurrences(of: "connection = \"github\"", with: "connection = \"other\"")
        try directory.writeProjectFile(id: "beta", betaText)
        let files = [directory.url.appending(component: "config.toml"),
                     directory.url.appending(components: "projects", "alpha.toml"), betaURL]
        let before = try files.map { try Data(contentsOf: $0) }
        let bindings = Mutex<[String]>([])
        let home = freshHomeDirectory()
        let control = RecordingLaunchAgentControl()
        let setup = try makeSetup(
            arguments: ["--install-jobs"], directory: directory, board: await makeBoard(),
            console: NoSetupPrompts(), homeDirectory: home, launchAgents: control,
            onBind: { entry in bindings.withLock { $0.append(entry.name) } }, isTTY: { isTTY }
        )

        try await setup.run()

        #expect(bindings.withLock { $0 } == ["acme", "other"])
        #expect(try files.map { try Data(contentsOf: $0) } == before)
        let labels = control.calls.compactMap { call -> String? in
            if case .bootstrap(let label) = call { return label }
            return nil
        }
        #expect(labels.count == 6)
        let secondControl = RecordingLaunchAgentControl(loadedLabels: Set(labels))
        let rerun = try makeSetup(
            arguments: ["--install-jobs"], directory: directory, board: await makeBoard(),
            console: NoSetupPrompts(), homeDirectory: home, launchAgents: secondControl, isTTY: { isTTY }
        )
        try await rerun.run()
        #expect(secondControl.calls == labels.map { .enable($0) })
        #expect(try files.map { try Data(contentsOf: $0) } == before)
    }

    @Test("Saved job requests also accept an existing Project and export jobs",
           arguments: ["saved-Project", "launchd", "cron"])
    func savedJobRequests(request: String) async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let export = freshHomeDirectory()
        let arguments = request == "saved-Project"
            ? ["--install-jobs", "--project", "alpha"] // glossary:ignore GL001
            : ["--export-jobs", export.path] + (request == "cron" ? ["--cron"] : [])
        let control = RecordingLaunchAgentControl()
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: await makeBoard(),
            console: NoSetupPrompts(), launchAgents: control, isTTY: { false }
        )

        try await setup.run()

        if request == "saved-Project" {
            #expect(control.calls.count == 6)
        } else {
            let files = try FileManager.default.contentsOfDirectory(atPath: export.path)
            #expect(files.count == (request == "cron" ? 1 : 3))
            #expect(control.calls.isEmpty)
        }
    }

    @Test("Non-terminal job requests that need configuration fail without reading stdin",
           arguments: ["machine", "Projects", "unknown-Project", "override"])
    func missingConfiguration(reason: String) async throws {
        let directory = ConfigurationDirectory()
        if reason != "machine" { try directory.writeMachineFile() }
        if reason == "unknown-Project" || reason == "override" {
            try directory.writeValidProjectFile(id: "alpha")
        }
        let arguments = ["--install-jobs"]
            + (reason == "unknown-Project" ? ["--project", "missing"] : []) // glossary:ignore GL001
            + (reason == "override" ? ["--board-connection", "acme"] : [])
        let control = RecordingLaunchAgentControl()
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: await makeBoard(),
            console: NoSetupPrompts(), launchAgents: control, isTTY: { false }
        )

        do {
            try await setup.run()
            Issue.record("Missing setup input should fail")
        } catch let error as SetupError {
            let message = String(describing: error)
            #expect(message.contains("standard input is not a terminal"))
            #expect(message.contains("yh setup --init"))
            #expect(!message.contains("cancelled"))
        }
        #expect(control.calls.isEmpty)
        if reason == "machine" {
            #expect(!FileManager.default.fileExists(atPath: directory.url.appending(component: "config.toml").path))
        }
    }

    @Test("An invalid saved connection is reported while a valid sibling still installs")
    func invalidSavedConnection() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        try directory.writeProjectFile(id: "beta", """
            id = "beta"
            name = "beta"
            board = { linear = { connection = "missing", project = "beta" } }
            code_hosting = { connection = "github" }
            spec_source = "~/Developer/beta-spec"

            [[repos]]
            name = "backend"
            path = "~/Developer/beta-backend"
            role = "backend"
            check = "swift test"
            """)
        let output = RecordingOutput()
        let control = RecordingLaunchAgentControl()
        let setup = try makeSetup(
            arguments: ["--install-jobs"], directory: directory, board: await makeBoard(),
            console: NoSetupPrompts(), output: output, launchAgents: control, isTTY: { false }
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(output.lines.contains { $0.contains("missing") })
        #expect(control.calls.contains(.bootstrap("dev.yellowhammer.alpha.author")))
        #expect(!control.calls.contains(.bootstrap("dev.yellowhammer.beta.author")))
    }

    @Test("Explicit declaration options retain the terminal wizard")
    func explicitDeclarationKeepsWizard() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let console = ScriptedConsole(answers: ["1", "1", "n"])
        let setup = try makeSetup(
            arguments: ["--install-jobs", "--project", "alpha", "--project-name", "Alpha", // glossary:ignore GL001
                        "--operator", "user-op"],
            directory: directory, board: await makeBoard(), console: console, isTTY: { true }
        )

        try await setup.run()

        #expect(console.prompts.count == 3)
        #expect(console.prompts.last == "Declare a Project now? [y/N] ")
    }
}
