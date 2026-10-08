import ArgumentParser
import Config
@testable import EngineCommand
import Foundation
import Testing

@Suite("yh setup --install-cli and --uninstall-cli")
struct SetupCLITests {
    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(component: "yh-setup-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let canonical = ExecutableFile.resolvedPath(tempDir.path) ?? tempDir.path
        return URL(filePath: canonical)
    }

    @Test("Exclusivity: --install-cli and --uninstall-cli cannot combine")
    func cannotCombineInstallAndUninstall() {
        #expect(throws: (any Error).self) {
            try SetupCommand.parse(["--install-cli", "--uninstall-cli"])
        }
    }

    @Test("Exclusivity: --install-cli cannot combine with other modes or project options", arguments: [
        ["--install-cli", "--init"],
        ["--install-cli", "--config", "/tmp"],
        ["--install-cli", "--print-choices"],
        ["--install-cli", "--install-linear"],
        ["--install-cli", "--install-jobs"],
        ["--install-cli", "--export-jobs"],
        ["--install-cli", "--project", "demo"],
        ["--install-cli", "--cli", "claude"],
        ["--install-cli", "--route", "linear=claude"]
    ])
    func cannotCombineInstallCLIWithOtherFlags(arguments: [String]) {
        #expect(throws: (any Error).self) {
            try SetupCommand.parse(arguments)
        }
    }

    @Test("Exclusivity: --uninstall-cli cannot combine with other modes or project options", arguments: [
        ["--uninstall-cli", "--init"],
        ["--uninstall-cli", "--config", "/tmp"],
        ["--uninstall-cli", "--print-choices"],
        ["--uninstall-cli", "--install-linear"],
        ["--uninstall-cli", "--install-jobs"],
        ["--uninstall-cli", "--export-jobs"],
        ["--uninstall-cli", "--project", "demo"]
    ])
    func cannotCombineUninstallCLIWithOtherFlags(arguments: [String]) {
        #expect(throws: (any Error).self) {
            try SetupCommand.parse(arguments)
        }
    }

    @Test("install-cli: already installed exits 0 and prints status")
    func installCLIAlreadyInstalled() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runningURL = tempDir.appending(component: "running_yh")
        try "binary".write(to: runningURL, atomically: true, encoding: .utf8)
        let linkURL = tempDir.appending(component: "yh")
        let link = CommandLineToolLink(path: linkURL.path)
        try link.install(target: runningURL.path)

        let directory = ConfigurationDirectory()
        let board = await makeBoard()
        let output = RecordingOutput()

        let setup = try makeSetup(
            arguments: ["--install-cli"],
            directory: directory,
            board: board,
            output: output,
            yhExecutablePath: runningURL.path,
            commandLineToolLink: link
        )

        try await setup.run()
        #expect(output.lines.contains { $0.contains("already installed") })
        // Does not create machine file
        #expect(!FileManager.default.fileExists(atPath: directory.url.appending(component: "config.toml").path))
    }

    @Test("install-cli: unprivileged install when directory is writable")
    func installCLIWritableDirectory() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runningURL = tempDir.appending(component: "running_yh")
        try "binary".write(to: runningURL, atomically: true, encoding: .utf8)
        let linkURL = tempDir.appending(component: "yh")
        let link = CommandLineToolLink(path: linkURL.path)

        let directory = ConfigurationDirectory()
        let board = await makeBoard()
        let output = RecordingOutput()

        let setup = try makeSetup(
            arguments: ["--install-cli"],
            directory: directory,
            board: board,
            output: output,
            yhExecutablePath: runningURL.path,
            commandLineToolLink: link
        )

        try await setup.run()
        #expect(output.lines.contains { $0.contains("Installed Command Line Tool symlink") })
        #expect(link.inspect(runningExecutable: runningURL.path) == .installed)
    }

    @Test("install-cli: directory not writable + TTY runs sudo")
    func installCLINotWritableTTY() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runningURL = tempDir.appending(component: "running_yh")
        try "binary".write(to: runningURL, atomically: true, encoding: .utf8)
        let fakeLink = CommandLineToolLink(path: "/nonexistent/usr/local/bin/yh")

        let directory = ConfigurationDirectory()
        let board = await makeBoard()
        let output = RecordingOutput()
        var ranSudoCommand: String?

        let setup = try makeSetup(
            arguments: ["--install-cli"],
            directory: directory,
            board: board,
            output: output,
            yhExecutablePath: runningURL.path,
            commandLineToolLink: fakeLink,
            isTTY: { true },
            runSudo: { cmd in
                ranSudoCommand = cmd
                return 0
            }
        )

        try await setup.run()
        #expect(ranSudoCommand != nil)
        #expect(ranSudoCommand?.contains("ln -sfh") == true)
        #expect(output.lines.contains { $0.contains("Installed Command Line Tool symlink") })
    }

    @Test("install-cli: directory not writable + non-TTY prints command and exits 1")
    func installCLINotWritableNonTTY() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runningURL = tempDir.appending(component: "running_yh")
        try "binary".write(to: runningURL, atomically: true, encoding: .utf8)
        let fakeLink = CommandLineToolLink(path: "/nonexistent/usr/local/bin/yh")

        let directory = ConfigurationDirectory()
        let board = await makeBoard()
        let output = RecordingOutput()

        let setup = try makeSetup(
            arguments: ["--install-cli"],
            directory: directory,
            board: board,
            output: output,
            yhExecutablePath: runningURL.path,
            commandLineToolLink: fakeLink,
            isTTY: { false }
        )

        await #expect(throws: ExitCode.self) {
            try await setup.run()
        }
        #expect(output.lines.contains { $0.contains("sudo /bin/sh -c") })
    }

    @Test("install-cli: non-symlink file at link path is refused")
    func installCLIRefusesNonSymlink() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runningURL = tempDir.appending(component: "running_yh")
        try "binary".write(to: runningURL, atomically: true, encoding: .utf8)
        let linkURL = tempDir.appending(component: "yh")
        try "regular-file".write(to: linkURL, atomically: true, encoding: .utf8)

        let link = CommandLineToolLink(path: linkURL.path)
        let directory = ConfigurationDirectory()
        let board = await makeBoard()
        let output = RecordingOutput()

        let setup = try makeSetup(
            arguments: ["--install-cli"],
            directory: directory,
            board: board,
            output: output,
            yhExecutablePath: runningURL.path,
            commandLineToolLink: link
        )

        do {
            try await setup.run()
            Issue.record("Expected SetupError")
        } catch let error as SetupError {
            #expect(error.message.contains("refusing to replace"))
        }
    }

    @Test("uninstall-cli: absent link exits 0 and prints status")
    func uninstallCLIAbsent() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkURL = tempDir.appending(component: "yh")
        let link = CommandLineToolLink(path: linkURL.path)

        let directory = ConfigurationDirectory()
        let board = await makeBoard()
        let output = RecordingOutput()

        let setup = try makeSetup(
            arguments: ["--uninstall-cli"],
            directory: directory,
            board: board,
            output: output,
            commandLineToolLink: link
        )

        try await setup.run()
        #expect(output.lines.contains { $0.contains("not installed") })
    }

    @Test("uninstall-cli: unprivileged uninstall when link points to yh")
    func uninstallCLIEligible() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkURL = tempDir.appending(component: "yh")
        let link = CommandLineToolLink(path: linkURL.path)
        try link.install(target: "/Applications/Yellowhammer.app/Contents/MacOS/yh")
        #expect((try? FileManager.default.attributesOfItem(atPath: linkURL.path)) != nil)

        let directory = ConfigurationDirectory()
        let board = await makeBoard()
        let output = RecordingOutput()

        let setup = try makeSetup(
            arguments: ["--uninstall-cli"],
            directory: directory,
            board: board,
            output: output,
            commandLineToolLink: link
        )

        try await setup.run()
        #expect(output.lines.contains { $0.contains("Removed Command Line Tool symlink") })
        #expect((try? FileManager.default.attributesOfItem(atPath: linkURL.path)) == nil)
    }

    @Test("uninstall-cli: ineligible symlink is refused")
    func uninstallCLIRefusesIneligible() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkURL = tempDir.appending(component: "yh")
        let link = CommandLineToolLink(path: linkURL.path)
        let otherTarget = tempDir.appending(component: "other").path
        try "other".write(toFile: otherTarget, atomically: true, encoding: .utf8)
        try link.install(target: otherTarget)

        let directory = ConfigurationDirectory()
        let board = await makeBoard()
        let output = RecordingOutput()

        let setup = try makeSetup(
            arguments: ["--uninstall-cli"],
            directory: directory,
            board: board,
            output: output,
            commandLineToolLink: link
        )

        do {
            try await setup.run()
            Issue.record("Expected SetupError")
        } catch let error as SetupError {
            #expect(error.message.contains("refusing to remove"))
        }
        #expect((try? FileManager.default.attributesOfItem(atPath: linkURL.path)) != nil)
    }
}
