@testable import EngineCommand
import Foundation
import Testing

/// A job that has run many times makes `launchctl print` print well past 4 KiB; on a Mac mini
/// that had fired its build job 15 times, doctor called the loaded job "not loaded".
@Suite("launchctl output limit")
struct LaunchctlOutputLimitTests {
    /// A stub `launchctl` that exits 0 after printing a long, well-formed `print` dump.
    private static func makeStub() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "launchctl-stub-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stub = directory.appending(component: "launchctl", directoryHint: .notDirectory)
        let script = """
            #!/bin/sh
            printf 'gui/501/dev.yellowhammer.alpha.build = {\\n\\truns = 15\\n\\tlast exit code = 0\\n'
            i=0
            while [ $i -lt 400 ]; do printf '\\t\\tevent %d = padding padding padding\\n' $i; i=$((i + 1)); done
            printf '}\\n'
            """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    @Test("A loaded job whose print output exceeds 4 KiB is still loaded, and its job info reads")
    func longPrintOutputIsLoaded() async throws {
        let stub = try Self.makeStub()
        defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
        let control = LaunchctlLaunchAgentControl(launchctlPath: stub.path, uid: 501)

        #expect(await control.isLoaded(label: "dev.yellowhammer.alpha.build"))
        let info = await control.jobInfo(label: "dev.yellowhammer.alpha.build")
        #expect(info == LaunchctlJobInfo(runs: 15, lastExitCode: 0))
    }
}
