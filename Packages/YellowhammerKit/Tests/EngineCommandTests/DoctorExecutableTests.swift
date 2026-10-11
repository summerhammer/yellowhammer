import Config
import Domain
@testable import EngineCommand
import Foundation
import GRDB
import Journal
import Testing

private let currentYH = "/Applications/Current.app/Contents/MacOS/yh"
private let otherYH = "/Applications/Other.app/Contents/MacOS/yh"

private struct ExecutableFixture {
    let home: URL
    let url: URL
    let job: ScheduledJob

    init(project: String = "alpha", executable: String = otherYH, stale: Bool = false) throws {
        home = freshHomeDirectory()
        let directory = home.appending(components: "Library", "LaunchAgents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firings = try Schedule().firings(staggerIndex: project == "alpha" ? 0 : 1).build
        job = ScheduledJob(
            projectID: try #require(ProjectID(rawValue: project)), act: .build, yhExecutablePath: executable,
            firings: stale ? Array(firings.dropFirst()) : firings, pathValue: "/usr/bin:/bin"
        )
        url = directory.appending(component: job.fileName)
        try job.plistData(homeDirectory: home.path()).write(to: url)
    }

    func cleanup() { try? FileManager.default.removeItem(at: home) }
    func path() throws -> String { try #require((decodePlist(at: url)["ProgramArguments"] as? [String])?.first) }
}

private func executableDirectory() throws -> ConfigurationDirectory {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    return directory
}

@Suite("Doctor: installed LaunchAgent executable verification")
struct DoctorExecutableTests {
    @Test("Missing executable fails even when schedule matches; --fix repairs it as a finding")
    func missingExecutable() async throws {
        let directory = try executableDirectory()
        let fixture = try ExecutableFixture()
        defer { fixture.cleanup() }
        let control = RecordingLaunchAgentControl(loadedLabels: [fixture.job.label])
        let doctor = makeDoctor(
            directory: directory, homeDirectory: fixture.home, launchAgents: control,
            checks: [.launchd], runningExecutablePath: currentYH, fileExists: { $0 == currentYH }
        )
        let before = await doctor.run()
        #expect(before.contains { $0.subject == fixture.job.label && $0.severity == .failure })
        let repairing = makeDoctor(
            directory: directory, homeDirectory: fixture.home, launchAgents: control,
            fix: true, checks: [.launchd], runningExecutablePath: currentYH, fileExists: { $0 == currentYH }
        )
        let after = await repairing.run()
        #expect(try fixture.path() == currentYH)
        #expect(after.contains {
            $0.subject == fixture.job.label && $0.severity == .pass && $0.message.contains("repointed")
        })
        #expect(!after.contains { $0.subject == fixture.job.label && $0.severity == .failure })
    }

    @Test("Mismatched executable only warns and stays byte-identical without --repoint")
    func mismatchWithoutRepoint() async throws {
        let directory = try executableDirectory()
        let fixture = try ExecutableFixture()
        defer { fixture.cleanup() }
        let bytes = try Data(contentsOf: fixture.url)
        let control = RecordingLaunchAgentControl(loadedLabels: [fixture.job.label])
        let findings = await makeDoctor(
            directory: directory, homeDirectory: fixture.home, launchAgents: control,
            fix: true, checks: [.launchd], runningExecutablePath: currentYH, fileExists: { _ in true }
        ).run()
        #expect(findings.contains {
            $0.subject == fixture.job.label && $0.severity == .warning && $0.message.contains("mismatched")
        })
        #expect(!findings.contains { $0.severity == .failure })
        #expect(try Data(contentsOf: fixture.url) == bytes)
        #expect(control.calls.isEmpty)
    }

    @Test("Stale schedule and mismatch share one rewrite; --repoint preserves configured stagger")
    func repairsTogether() async throws {
        let directory = try executableDirectory()
        try directory.writeValidProjectFile(id: "beta")
        let fixture = try ExecutableFixture(project: "beta", stale: true)
        defer { fixture.cleanup() }
        let control = RecordingLaunchAgentControl(loadedLabels: [fixture.job.label])
        let findings = await makeDoctor(
            directory: directory, homeDirectory: fixture.home, launchAgents: control,
            fix: true, repoint: true, checks: [.launchd], projectFilter: fixture.job.projectID,
            runningExecutablePath: currentYH, fileExists: { _ in true }
        ).run()
        #expect(try fixture.path() == currentYH)
        #expect(control.calls.filter { $0 == .bootout(fixture.job.label) }.count == 1)
        #expect(control.calls.filter { $0 == .bootstrap(fixture.job.label) }.count == 1)
        let expected = Set(try Schedule().firings(staggerIndex: 1).build)
        #expect(Doctor.installedFirings(in: try Data(contentsOf: fixture.url)) == expected)
        #expect(findings.contains { $0.message.contains("repointed") })
    }

    @Test("Running jobs and reload failures leave missing executable failure, never report repoint",
           arguments: [true, false])
    func unsuccessfulRepair(running: Bool) async throws {
        let directory = try executableDirectory()
        let fixture = try ExecutableFixture()
        defer { fixture.cleanup() }
        let before = try Data(contentsOf: fixture.url)
        let control = RecordingLaunchAgentControl(
            loadedLabels: [fixture.job.label], states: running ? [fixture.job.label: [.running]] : [:],
            bootstrapFailures: running ? [:] : [fixture.job.label: 1]
        )
        let findings = await makeDoctor(
            directory: directory, homeDirectory: fixture.home, launchAgents: control,
            fix: true, checks: [.launchd], runningExecutablePath: currentYH, fileExists: { $0 == currentYH }
        ).run()
        #expect(try Data(contentsOf: fixture.url) == before)
        #expect(findings.contains { $0.subject == fixture.job.label && $0.severity == .failure })
        #expect(!findings.contains { $0.subject == fixture.job.label && $0.message.contains("repointed") })
        if running { #expect(control.calls.isEmpty) }
    }

    @Test("Repoint leaves paused jobs unloaded")
    func pausedRepoint() async throws {
        let directory = try executableDirectory()
        let fixture = try ExecutableFixture()
        defer { fixture.cleanup() }
        let control = RecordingLaunchAgentControl()
        let findings = await makeDoctor(
            directory: directory, homeDirectory: fixture.home, launchAgents: control,
            fix: true, repoint: true, checks: [.launchd], runningExecutablePath: currentYH, fileExists: { _ in true }
        ).run()
        #expect(try fixture.path() == currentYH)
        #expect(control.calls.isEmpty)
        #expect(findings.contains { $0.subject == fixture.job.label && $0.message.contains("not loaded") })
        #expect(findings.contains { $0.message.contains("repointed") })
    }

    @Test("Project filter prevents executable repair in a sibling")
    func projectFilter() async throws {
        let directory = try executableDirectory()
        try directory.writeValidProjectFile(id: "beta")
        let fixture = try ExecutableFixture(project: "beta")
        defer { fixture.cleanup() }
        let before = try Data(contentsOf: fixture.url)
        let control = RecordingLaunchAgentControl()
        _ = await makeDoctor(
            directory: directory, homeDirectory: fixture.home, launchAgents: control,
            fix: true, repoint: true, checks: [.launchd], projectFilter: ProjectID(rawValue: "alpha"),
            runningExecutablePath: currentYH, fileExists: { _ in true }
        ).run()
        #expect(try Data(contentsOf: fixture.url) == before)
        #expect(control.calls.isEmpty)
    }

    @Test("A stale schedule with the current executable still reports executable pass")
    func staleCurrentExecutable() async throws {
        let directory = try executableDirectory()
        let fixture = try ExecutableFixture(executable: currentYH, stale: true)
        defer { fixture.cleanup() }
        let findings = await makeDoctor(
            directory: directory, homeDirectory: fixture.home,
            launchAgents: RecordingLaunchAgentControl(loadedLabels: [fixture.job.label]),
            checks: [.launchd], runningExecutablePath: currentYH, fileExists: { _ in true }
        ).run()
        #expect(findings.contains { $0.severity == .warning && $0.message.contains("differs") })
        #expect(findings.contains { $0.severity == .pass && $0.message.contains("executable resolves") })
    }

    @Test("Schedule regeneration validates the retained foreign executable", arguments: ["unknown", "older", "equal"])
    func retainedExecutableSchema(kind: String) async throws {
        let directory = try executableDirectory()
        let fixture = try ExecutableFixture(stale: true)
        defer { fixture.cleanup() }
        let store = try JournalStore.open(
            configurationDirectory: directory.url, projectID: fixture.job.projectID,
            linearWorkspace: BoardObjectID(rawValue: "workspace-1")
        )
        let current = try #require(JournalStore.migrationIdentifiers.last)
        let before = try Data(contentsOf: fixture.url)
        var doctor = makeDoctor(
            directory: directory, homeDirectory: fixture.home, fix: true,
            checks: [.launchd], runningExecutablePath: currentYH, fileExists: { _ in true }
        )
        doctor.executableSchema = { _ in
            kind == "unknown" ? nil : (kind == "older" ? "journal-schema-1" : current)
        }
        let findings = await doctor.run()
        #expect(try fixture.path() == otherYH)
        #expect((try Data(contentsOf: fixture.url) == before) == (kind != "equal"))
        #expect(findings.contains { $0.message.contains("refused regeneration") } == (kind != "equal"))
        _ = store
    }

    @Test("Schema newer than chosen engine refuses regeneration read-only", arguments: [true, false])
    func schemaGuard(repoint: Bool) async throws {
        let directory = try executableDirectory()
        let fixture = try ExecutableFixture(stale: true)
        defer { fixture.cleanup() }
        let journalURL = JournalStore.defaultFileURL(configurationDirectory: directory.url, id: fixture.job.projectID)
        let store = try JournalStore.open(
            configurationDirectory: directory.url, projectID: fixture.job.projectID,
            linearWorkspace: BoardObjectID(rawValue: "workspace-1")
        )
        let current = try #require(JournalStore.migrationIdentifiers.last)
        #expect(try JournalStore.schemaIdentifier(at: journalURL) == current)
        let queue = try DatabaseQueue(path: journalURL.path())
        try await queue.write { database in
            try database.execute(sql: "UPDATE grdb_migrations SET identifier = 'journal-schema-999'")
        }
        let before = try Data(contentsOf: fixture.url)
        let journalBefore = try Data(contentsOf: journalURL)
        var doctor = makeDoctor(
            directory: directory, homeDirectory: fixture.home, fix: true, repoint: repoint,
            checks: [.launchd], runningExecutablePath: currentYH, fileExists: { _ in true }
        )
        doctor.executableSchema = { _ in current }
        let findings = await doctor.run()
        #expect(try Data(contentsOf: fixture.url) == before)
        #expect(try Data(contentsOf: journalURL) == journalBefore)
        #expect(findings.contains {
            $0.severity == .failure && $0.message.contains("journal-schema-999") && $0.message.contains(current)
        })
        _ = store
    }
}

@Suite("Scheduled executable safety")
struct ScheduledExecutableTests {
    @Test("Directories and files without execute permission are missing executables")
    func nonRunnableFiles() throws {
        let directory = freshHomeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(component: "yh")
        try Data("not executable".utf8).write(to: file)
        for path in [directory.path(), file.path()] {
            #expect(ScheduledExecutable.inspect(
                path, running: currentYH, fileExists: ExecutableFile.isRunnable
            ) == .missing)
        }
    }

    @Test("--repoint requires --fix")
    func flags() throws {
        #expect(throws: (any Error).self) { try DoctorCommand.parse(["--repoint"]) }
        #expect(try DoctorCommand.parse(["--fix", "--repoint"]).repoint)
    }

    @Test("Symlink paths compare by resolved target")
    func resolvedComparison() throws {
        let directory = freshHomeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(component: "yh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path())
        let link = directory.appending(component: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        #expect(ScheduledExecutable.inspect(
            link.path(), running: executable.path(), fileExists: ExecutableFile.isRunnable
        ) == .running)
    }

    @Test("Missing Journal inspection never creates a file; unknown and older engine schemas are refused")
    func schemaCompatibility() throws {
        let url = freshHomeDirectory().appending(component: "missing.db")
        #expect(try JournalStore.schemaIdentifier(at: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path()))
        try ScheduledExecutable.validateSchema("journal-schema-9", journal: "journal-schema-8")
        #expect(throws: (any Error).self) {
            try ScheduledExecutable.validateSchema("journal-schema-8", journal: "journal-schema-9")
        }
        #expect(throws: (any Error).self) { try ScheduledExecutable.validateSchema(nil, journal: "journal-schema-9") }
        #expect(throws: (any Error).self) {
            try ScheduledExecutable.validateSchema("journal-schema-9", journal: "unknown")
        }
    }

    @Test("Foreign capability query accepts metadata, fails closed on invalid output or exit, and times out",
           arguments: ["valid", "invalid", "failed", "timeout"])
    func foreignQuery(kind: String) async throws {
        let directory = freshHomeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appending(component: "yh")
        let body: String
        switch kind {
        case "valid": body = "[ \"$1\" = journal-schema ] || exit 3\necho '{\"schema\":\"journal-schema-9\"}'"
        case "invalid": body = "echo invalid"
        case "failed": body = "echo '{\"schema\":\"journal-schema-9\"}'\nexit 1"
        default: body = "exec /bin/sleep 10"
        }
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path())
        let result = kind == "timeout"
            ? await ScheduledExecutable.querySchema(script.path(), timeout: 0.2)
            : await ScheduledExecutable.schema(script.path())
        #expect(result == (kind == "valid" ? "journal-schema-9" : nil))
    }

    @Test("Translocation refuses regeneration and names Finder remedy")
    func translocation() throws {
        #expect(throws: (any Error).self) {
            try ScheduledExecutable.validateLocation(
                "/private/var/folders/x/AppTranslocation/y/Yellowhammer.app/Contents/MacOS/yh",
                homeDirectory: freshHomeDirectory(), output: { _ in }
            )
        }
    }
}
