import Config
import Darwin
import Foundation
import Testing

@Suite("CommandLineToolLink: inspect, install, uninstall, and privileged commands")
struct CommandLineToolLinkTests {
    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(component: "yh-clitool-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let canonical = ExecutableFile.resolvedPath(tempDir.path) ?? tempDir.path
        return URL(filePath: canonical)
    }

    @Test("inspect: notInstalled when path does not exist")
    func inspectNotInstalled() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkPath = tempDir.appending(component: "yh").path
        let link = CommandLineToolLink(path: linkPath)

        let state = link.inspect(runningExecutable: "/Applications/Yellowhammer.app/Contents/MacOS/yh")
        #expect(state == .notInstalled)
    }

    @Test("inspect: installed when symlink resolves to runningExecutable")
    func inspectInstalled() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = tempDir.appending(component: "running_yh")
        try "executable-binary".write(to: targetURL, atomically: true, encoding: .utf8)

        let linkPath = tempDir.appending(component: "yh").path
        let link = CommandLineToolLink(path: linkPath)
        try link.install(target: targetURL.path)

        let state = link.inspect(runningExecutable: targetURL.path)
        #expect(state == .installed)
    }

    @Test("inspect: dangling when symlink target does not exist")
    func inspectDangling() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let nonexistentTarget = tempDir.appending(component: "ghost_yh").path
        let linkPath = tempDir.appending(component: "yh").path
        symlink(nonexistentTarget, linkPath)

        let link = CommandLineToolLink(path: linkPath)
        let state = link.inspect(runningExecutable: "/Applications/Yellowhammer.app/Contents/MacOS/yh")
        #expect(state == .dangling(target: nonexistentTarget))
    }

    @Test("inspect: mismatched when symlink points to different file")
    func inspectMismatchedSymlink() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let otherTarget = tempDir.appending(component: "other_yh")
        try "other".write(to: otherTarget, atomically: true, encoding: .utf8)
        let runningTarget = tempDir.appending(component: "running_yh")
        try "running".write(to: runningTarget, atomically: true, encoding: .utf8)

        let linkPath = tempDir.appending(component: "yh").path
        let link = CommandLineToolLink(path: linkPath)
        try link.install(target: otherTarget.path)

        let state = link.inspect(runningExecutable: runningTarget.path)
        let expectedTarget = ExecutableFile.resolvedPath(otherTarget.path) ?? otherTarget.path
        #expect(state == .mismatched(target: expectedTarget))
    }

    @Test("inspect: mismatched when regular non-symlink file exists at path")
    func inspectMismatchedRegularFile() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkPath = tempDir.appending(component: "yh").path
        try "regular-file".write(toFile: linkPath, atomically: true, encoding: .utf8)

        let link = CommandLineToolLink(path: linkPath)
        let state = link.inspect(runningExecutable: "/Applications/Yellowhammer.app/Contents/MacOS/yh")
        #expect(state == .mismatched(target: linkPath))
    }

    @Test("install: creates symlink with mode 0755 even under restrictive umask")
    func installSets0755Mode() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = tempDir.appending(component: "running_yh")
        try "target".write(to: targetURL, atomically: true, encoding: .utf8)

        let linkPath = tempDir.appending(component: "yh").path
        let link = CommandLineToolLink(path: linkPath)

        // Set restrictive umask 0o077 during install to verify lchmod explicitly sets 0755
        let oldUmask = umask(0o077)
        defer { umask(oldUmask) }

        try link.install(target: targetURL.path)

        var st = stat()
        #expect(lstat(linkPath, &st) == 0)
        #expect((st.st_mode & S_IFMT) == S_IFLNK)
        #expect((st.st_mode & 0o777) == 0o755)
    }

    @Test("install: repoints cleanly over existing symlink")
    func installRepointsOverExistingSymlink() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let target1 = tempDir.appending(component: "target1")
        try "1".write(to: target1, atomically: true, encoding: .utf8)
        let target2 = tempDir.appending(component: "target2")
        try "2".write(to: target2, atomically: true, encoding: .utf8)

        let linkPath = tempDir.appending(component: "yh").path
        let link = CommandLineToolLink(path: linkPath)

        try link.install(target: target1.path)
        #expect(link.inspect(runningExecutable: target1.path) == .installed)

        try link.install(target: target2.path)
        #expect(link.inspect(runningExecutable: target2.path) == .installed)
        #expect(link.inspect(runningExecutable: target1.path) != .installed)
    }

    @Test("install: refuses to replace a regular non-symlink file")
    func installRefusesRegularFile() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkPath = tempDir.appending(component: "yh").path
        try "do-not-overwrite".write(toFile: linkPath, atomically: true, encoding: .utf8)

        let link = CommandLineToolLink(path: linkPath)
        #expect(throws: CommandLineToolLinkError.refusedNonSymlink(linkPath)) {
            try link.install(target: "/some/target")
        }

        let content = try String(contentsOfFile: linkPath, encoding: .utf8)
        #expect(content == "do-not-overwrite")
    }

    @Test("uninstall: removes symlink whose target ends in /Contents/MacOS/yh")
    func uninstallRemovesEligibleSymlink() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkPath = tempDir.appending(component: "yh").path
        let link = CommandLineToolLink(path: linkPath)

        // Eligible even if dangling as long as destination path ends in /Contents/MacOS/yh
        let target = "/Applications/Yellowhammer.app/Contents/MacOS/yh"
        try link.install(target: target)
        #expect((try? FileManager.default.attributesOfItem(atPath: linkPath)) != nil)

        try link.uninstall()
        #expect((try? FileManager.default.attributesOfItem(atPath: linkPath)) == nil)
    }

    @Test("uninstall: refuses non-symlink regular file")
    func uninstallRefusesNonSymlink() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkPath = tempDir.appending(component: "yh").path
        try "regular-file".write(toFile: linkPath, atomically: true, encoding: .utf8)

        let link = CommandLineToolLink(path: linkPath)
        #expect(throws: CommandLineToolLinkError.refusedNonSymlink(linkPath)) {
            try link.uninstall()
        }
        #expect((try? FileManager.default.attributesOfItem(atPath: linkPath)) != nil)
    }

    @Test("uninstall: refuses symlink pointing to an ineligible target")
    func uninstallRefusesIneligibleTarget() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let target = tempDir.appending(component: "some_other_tool").path
        try "binary".write(toFile: target, atomically: true, encoding: .utf8)

        let linkPath = tempDir.appending(component: "yh").path
        let link = CommandLineToolLink(path: linkPath)
        try link.install(target: target)

        #expect(throws: CommandLineToolLinkError.refusedIneligibleSymlink(path: linkPath, target: target)) {
            try link.uninstall()
        }
        #expect((try? FileManager.default.attributesOfItem(atPath: linkPath)) != nil)
    }

    @Test("privileged commands: correct quoting for path with spaces and single quotes")
    func privilegedCommandsQuoting() {
        let linkPath = "/usr/local/bin/yh"
        let link = CommandLineToolLink(path: linkPath)

        let targetWithQuoteAndSpace = "/Applications/Yellow hammer's.app/Contents/MacOS/yh"
        let installCmd = link.privilegedInstallCommand(target: targetWithQuoteAndSpace)
        #expect(installCmd.contains("'/Applications/Yellow hammer'\\''s.app/Contents/MacOS/yh'"))
        #expect(installCmd.hasPrefix("/bin/mkdir -p -m 0755 /usr/local/bin"))
        #expect(installCmd.contains("/bin/chmod -h 0755 /usr/local/bin/yh"))

        let uninstallCmd = link.privilegedUninstallCommand()
        #expect(uninstallCmd == "/bin/rm -f /usr/local/bin/yh")

        // Non-default path
        let customLink = CommandLineToolLink(path: "/opt/custom bin/yh's")
        let customInstall = customLink.privilegedInstallCommand(target: targetWithQuoteAndSpace)
        #expect(customInstall.contains("'/opt/custom bin'"))
        #expect(customInstall.contains("'/opt/custom bin/yh'\\''s'"))

        let customUninstall = customLink.privilegedUninstallCommand()
        #expect(customUninstall == "/bin/rm -f '/opt/custom bin/yh'\\''s'")
    }

    @Test("appleScriptEscape: escapes backslashes and double quotes")
    func appleScriptEscaping() {
        let shellString = "/bin/sh -c 'echo \"hello \\ world\"'"
        let escaped = CommandLineToolLink.appleScriptEscape(shellString)
        #expect(escaped == "/bin/sh -c 'echo \\\"hello \\\\ world\\\"'")
    }

    @Test("runningExecutablePath: resolves symlinks in argv[0] to the canonical binary")
    func runningExecutablePathResolvesSymlinks() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let realBinary = tempDir.appending(component: "real_yh")
        try "#!/bin/sh\nexit 0".write(to: realBinary, atomically: true, encoding: .utf8)
        chmod(realBinary.path, 0o755)

        let symlink1 = tempDir.appending(component: "symlink1").path
        symlink(realBinary.path, symlink1)

        let symlink2 = tempDir.appending(component: "symlink2").path
        symlink(symlink1, symlink2)

        let resolved = CommandLineToolLink.runningExecutablePath(
            bundleExecutableURL: nil,
            argv0: symlink2,
            currentDirectory: tempDir.path
        )

        let expectedBinary = ExecutableFile.resolvedPath(realBinary.path) ?? realBinary.path
        #expect(resolved == expectedBinary)
    }
}
