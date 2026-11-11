import Darwin
import Domain
@testable import EngineCommand
import Foundation
import Testing

@Suite("Orca direct spawn endings", .timeLimit(.minutes(1)))
struct OrcaDirectSpawnEndingTests {
    @Test("Directly spawned CLI exit statuses remain attributable to the CLI")
    func nonzeroStatusesRemainHardFailures() async throws {
        for status in [129, 143] {
            let fixture = try OrcaTabPassFixture()
            defer { fixture.cleanUp() }
            let script = try writeScript(in: fixture, body: "exit \(status)\n", name: "exit-\(status).sh")
            let dispatch = try fixture.makeDispatch(scriptURL: script)
            let report = try await dispatch.dispatch(fixture.makeRequest(worktreeID: nil))

            #expect(report.outcome == .failed(exitStatus: Int32(status)))
            #expect(report.tabInterruption == nil)
            #expect(report.notShownInOrca == nil)
            #expect(!report.engineSignalled)
            #expect(report.receivedSignals.isEmpty)
        }
    }

    @Test("A directly spawned CLI may trap SIGINT, return structured output, and complete")
    func trappedInterruptCanComplete() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }
        let resultFile = fixture.tempDir.appendingPathComponent("interrupt-result.json")
        let resultJSON = #"""
        {"type":"result","structured_output":{
          "schema":"yellowhammer.result.worker", "version":1, "outcome":"completed",
          "commit":"0123456789abcdef0123456789abcdef01234567", "summary":"handled interrupt"
        },"session_id":"sess-direct-int"}
        """#
        try (resultJSON.replacingOccurrences(of: "\n", with: "") + "\n").write(
            to: resultFile,
            atomically: true,
            encoding: .utf8
        )
        let script = try writeScript(
            in: fixture,
            body:
            """
            trap 'cat \"\(resultFile.path)\"; exit 0' INT
            kill -INT $$
            while :; do sleep 0.02; done
            """,
            name: "trap-int.sh"
        )
        let dispatch = try fixture.makeDispatch(scriptURL: script)
        let report = try await dispatch.dispatch(fixture.makeRequest(worktreeID: nil))

        #expect(report.outcome.isCompleted)
        #expect(report.tabInterruption == nil)
        #expect(report.notShownInOrca == nil)
        #expect(!report.engineSignalled)
        #expect(report.receivedSignals.isEmpty)
    }

    @Test("A directly spawned CLI killed by SIGKILL remains Crashed-Unknown signaled")
    func sigkillRemainsCrashedUnknown() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }
        let script = try writeScript(in: fixture, body: "kill -KILL $$\n", name: "kill-self.sh")
        let dispatch = try fixture.makeDispatch(scriptURL: script)
        let report = try await dispatch.dispatch(fixture.makeRequest(worktreeID: nil))

        #expect(report.outcome == .crashedUnknown(.signaled(SIGKILL)))
        #expect(report.tabInterruption == nil)
        #expect(report.notShownInOrca == nil)
        #expect(!report.engineSignalled)
        #expect(report.receivedSignals.isEmpty)
    }

    private func writeScript(in fixture: OrcaTabPassFixture, body: String, name: String) throws -> URL {
        let url = fixture.tempDir.appendingPathComponent(name)
        try ("#!/bin/bash\nset +e\n" + body).write(to: url, atomically: true, encoding: .utf8)
        guard chmod(url.path, 0o755) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return url
    }
}
