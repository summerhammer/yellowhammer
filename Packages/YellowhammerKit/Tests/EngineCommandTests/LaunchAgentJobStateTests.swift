@testable import EngineCommand
import Foundation
import Testing

@Suite("launchctl replacement safety")
struct LaunchAgentRuntimeStateTests {
    @Test("Only top-level state and pid indicate a running job")
    func parseState() throws {
        #expect(try LaunchctlLaunchAgentControl.parseJobState("\tstate = running\n") == .running)
        #expect(try LaunchctlLaunchAgentControl.parseJobState("\tstate = waiting\n\tpid = 12\n") == .running)
        #expect(try LaunchctlLaunchAgentControl.parseJobState(
            "\tstate = not running\n\t\tstate = running\n\t\tpid = 99\n"
        ) == .idle)
        #expect(throws: LaunchctlError.self) { try LaunchctlLaunchAgentControl.parseJobState("") }
        #expect(throws: LaunchctlError.self) {
            try LaunchctlLaunchAgentControl.parseJobState("\tstate = mystery\n")
        }
        #expect(throws: LaunchctlError.self) {
            try LaunchctlLaunchAgentControl.parseJobState("\tstate = waiting\n\tpid = invalid\n")
        }
    }

    @Test("Only a service-not-found diagnostic means unloaded",
           arguments: ["missing", "denied", "empty", "bad", "overflow"])
    func inspectionFailures(scenario: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = directory.appending(component: "launchctl")
        let script: String
        switch scenario {
        case "missing":
            script = "#!/bin/sh\necho 'Could not find service \"dev.yellowhammer.alpha.author\" "
                + "in domain for user gui: 501' >&2\nexit 113\n"
        case "denied":
            script = "#!/bin/sh\necho 'Permission denied' >&2\nexit 113\n"
        case "empty": script = "#!/bin/sh\nexit 0\n"
        case "overflow": script = "#!/bin/sh\nprintf '%1048577s' ' '\nexit 0\n"
        default: script = "#!/bin/sh\necho 'unrecognized output'\nexit 0\n"
        }
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let control = LaunchctlLaunchAgentControl(launchctlPath: stub.path, uid: 501)
        if scenario == "missing" {
            #expect(try await control.jobState(label: "dev.yellowhammer.alpha.author") == .unloaded)
        } else {
            await #expect(throws: LaunchctlError.self) {
                try await control.jobState(label: "dev.yellowhammer.alpha.author")
            }
        }
    }

    @Test("A process launch failure cannot become unloaded")
    func processFailure() async {
        let control = LaunchctlLaunchAgentControl(launchctlPath: "/missing/launchctl", uid: 501)
        await #expect(throws: LaunchctlError.self) { try await control.jobState(label: "example") }
    }
}
