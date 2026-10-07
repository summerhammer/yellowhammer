import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

@Suite("Doctor: command line tool symlink check")
struct DoctorCLITests {
    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(component: "yh-doctor-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let canonical = ExecutableFile.resolvedPath(tempDir.path) ?? tempDir.path
        return URL(filePath: canonical)
    }

    @Test("Symlink installed reports .pass")
    func installedReportsPass() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runningURL = tempDir.appending(component: "running_yh")
        try "binary".write(to: runningURL, atomically: true, encoding: .utf8)
        let linkURL = tempDir.appending(component: "yh")
        let link = CommandLineToolLink(path: linkURL.path)
        try link.install(target: runningURL.path)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let doctor = makeDoctor(
            directory: directory,
            checks: [.launchd],
            commandLineToolLink: link,
            runningExecutablePath: runningURL.path
        )

        let findings = await doctor.run()
        let cliFinding = try #require(findings.first { $0.subject == linkURL.path })
        #expect(cliFinding.check == .launchd)
        #expect(cliFinding.severity == .pass)
        #expect(cliFinding.projectID == nil)
    }

    @Test("Symlink not installed reports .info and advises menu and yh setup --install-cli")
    func notInstalledReportsInfo() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkURL = tempDir.appending(component: "yh")
        let link = CommandLineToolLink(path: linkURL.path)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let doctor = makeDoctor(
            directory: directory,
            checks: [.launchd],
            commandLineToolLink: link,
            runningExecutablePath: "/Applications/Yellowhammer.app/Contents/MacOS/yh"
        )

        let findings = await doctor.run()
        let cliFinding = try #require(findings.first { $0.subject == linkURL.path })
        #expect(cliFinding.check == .launchd)
        #expect(cliFinding.severity == .info)
        #expect(cliFinding.message.contains("Yellowhammer → Install Command Line Tool…"))
        #expect(cliFinding.message.contains("yh setup --install-cli"))
        #expect(cliFinding.projectID == nil)
    }

    @Test("Dangling symlink reports .warning naming broken target")
    func danglingReportsWarning() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let nonexistent = tempDir.appending(component: "deleted_yh").path
        let linkURL = tempDir.appending(component: "yh")
        symlink(nonexistent, linkURL.path)

        let link = CommandLineToolLink(path: linkURL.path)
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let doctor = makeDoctor(
            directory: directory,
            checks: [.launchd],
            commandLineToolLink: link,
            runningExecutablePath: "/Applications/Yellowhammer.app/Contents/MacOS/yh"
        )

        let findings = await doctor.run()
        let cliFinding = try #require(findings.first { $0.subject == linkURL.path })
        #expect(cliFinding.severity == .warning)
        #expect(cliFinding.message.contains(nonexistent))
    }

    @Test("Mismatched symlink reports .warning naming current and running targets")
    func mismatchedReportsWarning() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let oldBinary = tempDir.appending(component: "old_yh")
        try "old".write(to: oldBinary, atomically: true, encoding: .utf8)
        let runningBinary = tempDir.appending(component: "running_yh")
        try "running".write(to: runningBinary, atomically: true, encoding: .utf8)

        let linkURL = tempDir.appending(component: "yh")
        let link = CommandLineToolLink(path: linkURL.path)
        try link.install(target: oldBinary.path)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let doctor = makeDoctor(
            directory: directory,
            checks: [.launchd],
            commandLineToolLink: link,
            runningExecutablePath: runningBinary.path
        )

        let findings = await doctor.run()
        let cliFinding = try #require(findings.first { $0.subject == linkURL.path })
        #expect(cliFinding.severity == .warning)
        #expect(cliFinding.message.contains(oldBinary.path))
        #expect(cliFinding.message.contains(runningBinary.path))
    }

    @Test("--fix repoints dangling symlink when parent directory is writable")
    func fixRepointsDanglingSymlink() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runningBinary = tempDir.appending(component: "running_yh")
        try "running".write(to: runningBinary, atomically: true, encoding: .utf8)

        let nonexistent = tempDir.appending(component: "deleted_yh").path
        let linkURL = tempDir.appending(component: "yh")
        symlink(nonexistent, linkURL.path)

        let link = CommandLineToolLink(path: linkURL.path)
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let output = RecordingOutput()

        let doctor = makeDoctor(
            directory: directory,
            output: output,
            fix: true,
            checks: [.launchd],
            commandLineToolLink: link,
            runningExecutablePath: runningBinary.path
        )

        let findings = await doctor.run()
        let cliFinding = try #require(findings.first { $0.subject == linkURL.path })
        #expect(cliFinding.severity == .pass)
        #expect(link.inspect(runningExecutable: runningBinary.path) == .installed)
        #expect(output.lines.contains { $0.contains("repointed Command Line Tool symlink") })
    }

    @Test("--fix repoints mismatched symlink when parent directory is writable")
    func fixRepointsMismatchedSymlink() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let oldBinary = tempDir.appending(component: "old_yh")
        try "old".write(to: oldBinary, atomically: true, encoding: .utf8)
        let runningBinary = tempDir.appending(component: "running_yh")
        try "running".write(to: runningBinary, atomically: true, encoding: .utf8)

        let linkURL = tempDir.appending(component: "yh")
        let link = CommandLineToolLink(path: linkURL.path)
        try link.install(target: oldBinary.path)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let output = RecordingOutput()

        let doctor = makeDoctor(
            directory: directory,
            output: output,
            fix: true,
            checks: [.launchd],
            commandLineToolLink: link,
            runningExecutablePath: runningBinary.path
        )

        let findings = await doctor.run()
        let cliFinding = try #require(findings.first { $0.subject == linkURL.path })
        #expect(cliFinding.severity == .pass)
        #expect(link.inspect(runningExecutable: runningBinary.path) == .installed)
    }

    @Test("--fix when parent directory is not writable prints sudo commands and keeps warning")
    func fixNotWritablePrintsSudoAdvice() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer {
            chmod(tempDir.path, 0o755)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let runningBinary = tempDir.appending(component: "running_yh")
        try "running".write(to: runningBinary, atomically: true, encoding: .utf8)

        let linkURL = tempDir.appending(component: "yh")
        symlink("/nonexistent/target", linkURL.path)

        chmod(tempDir.path, 0o555)

        let link = CommandLineToolLink(path: linkURL.path)
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let output = RecordingOutput()

        let doctor = makeDoctor(
            directory: directory,
            output: output,
            fix: true,
            checks: [.launchd],
            commandLineToolLink: link,
            runningExecutablePath: runningBinary.path
        )

        let findings = await doctor.run()
        let cliFinding = try #require(findings.first { $0.subject == linkURL.path })
        #expect(cliFinding.severity == .warning)
        #expect(output.lines.contains { $0.contains("sudo ln -sfh") })
        #expect(output.lines.contains { $0.contains("sudo chmod -h 0755") })
        #expect(output.lines.contains { $0.contains("Yellowhammer → Update Command Line Tool…") })
    }

    @Test("--fix does not create absent link")
    func fixDoesNotCreateAbsentLink() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkURL = tempDir.appending(component: "yh")
        let link = CommandLineToolLink(path: linkURL.path)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let doctor = makeDoctor(
            directory: directory,
            fix: true,
            checks: [.launchd],
            commandLineToolLink: link,
            runningExecutablePath: "/Applications/Yellowhammer.app/Contents/MacOS/yh"
        )

        let findings = await doctor.run()
        let cliFinding = try #require(findings.first { $0.subject == linkURL.path })
        #expect(cliFinding.severity == .info)
        #expect(link.inspect(runningExecutable: "/Applications/Yellowhammer.app/Contents/MacOS/yh") == .notInstalled)
    }

    @Test("--fix does not touch non-symlink file")
    func fixDoesNotTouchNonSymlink() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkURL = tempDir.appending(component: "yh")
        try "regular-file".write(to: linkURL, atomically: true, encoding: .utf8)
        let link = CommandLineToolLink(path: linkURL.path)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let doctor = makeDoctor(
            directory: directory,
            fix: true,
            checks: [.launchd],
            commandLineToolLink: link,
            runningExecutablePath: "/Applications/Yellowhammer.app/Contents/MacOS/yh"
        )

        let findings = await doctor.run()
        let cliFinding = try #require(findings.first { $0.subject == linkURL.path })
        #expect(cliFinding.severity == .warning)
        let content = try String(contentsOf: linkURL, encoding: .utf8)
        #expect(content == "regular-file")
    }

    @Test("Zero Projects configured still emits machine-scoped link finding")
    func zeroProjectsEmitsFinding() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkURL = tempDir.appending(component: "yh")
        let link = CommandLineToolLink(path: linkURL.path)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        // No project file written in directory!
        let doctor = makeDoctor(
            directory: directory,
            checks: [.launchd],
            commandLineToolLink: link,
            runningExecutablePath: "/Applications/Yellowhammer.app/Contents/MacOS/yh"
        )

        let findings = await doctor.run()
        let cliFindings = findings.filter { $0.subject == linkURL.path }
        #expect(cliFindings.count == 1)
        #expect(cliFindings[0].severity == .info)
    }

    @Test("Project filter keeps machine-scoped link finding")
    func projectFilterKeepsMachineScopedFinding() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkURL = tempDir.appending(component: "yh")
        let link = CommandLineToolLink(path: linkURL.path)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let filterID = try #require(ProjectID(rawValue: "alpha"))
        let doctor = makeDoctor(
            directory: directory,
            checks: [.launchd],
            projectFilter: filterID,
            commandLineToolLink: link,
            runningExecutablePath: "/Applications/Yellowhammer.app/Contents/MacOS/yh"
        )

        let findings = await doctor.run()
        let cliFindings = findings.filter { $0.subject == linkURL.path }
        #expect(cliFindings.count == 1)
    }
}
