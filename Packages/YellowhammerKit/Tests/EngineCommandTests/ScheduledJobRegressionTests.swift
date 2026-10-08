import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

@Suite("ScheduledJob regression: ProgramArguments[0] never uses a symlink")
struct ScheduledJobRegressionTests {
    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(component: "yh-job-regression-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let canonical = ExecutableFile.resolvedPath(tempDir.path) ?? tempDir.path
        return URL(filePath: canonical)
    }

    @Test("Invoking yh through a symlink resolves to bundle binary in ScheduledJob ProgramArguments[0]")
    func scheduledJobUsesResolvedBundleBinary() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a simulated app bundle with executable
        let appBundle = tempDir
            .appending(components: "Yellowhammer.app", "Contents", "MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)
        let bundleBinaryURL = appBundle.appending(component: "yh")
        try "#!/bin/sh\nexit 0".write(to: bundleBinaryURL, atomically: true, encoding: .utf8)
        chmod(bundleBinaryURL.path, 0o755)

        // Create symlink simulating /usr/local/bin/yh pointing to bundle binary
        let symlinkURL = tempDir.appending(component: "yh_symlink")
        symlink(bundleBinaryURL.path, symlinkURL.path)

        // Simulate invocation where argv[0] is the symlink
        let resolvedPath = CommandLineToolLink.runningExecutablePath(
            bundleExecutableURL: nil,
            argv0: symlinkURL.path,
            currentDirectory: tempDir.path
        )

        let projectID = try #require(ProjectID(rawValue: "alpha"))
        let job = ScheduledJob(
            projectID: projectID,
            act: .author,
            yhExecutablePath: resolvedPath,
            firings: [try #require(TimeOfDay(hour: 22, minute: 0))],
            pathValue: "/usr/bin:/bin"
        )

        let plistData = try job.plistData(homeDirectory: tempDir.path)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try #require(
            PropertyListSerialization.propertyList(from: plistData, options: [], format: &format) as? [String: Any]
        )

        let programArguments = try #require(plist["ProgramArguments"] as? [String])
        #expect(programArguments[0] == bundleBinaryURL.path)
        #expect(programArguments[0] != symlinkURL.path)
    }
}
