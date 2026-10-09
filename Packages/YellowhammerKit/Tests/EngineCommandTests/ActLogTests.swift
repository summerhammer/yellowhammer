import ArgumentParser
import Domain
import Engine
@testable import EngineCommand
import Foundation
import Journal
import Testing

// An Act's diagnostic log line carries a timestamp because launchd's does not.

@Suite("ActLog: timestamped Act failures")
struct ActLogTests {
    private struct Refusal: Error, CustomStringConvertible {
        var description: String { "the board refused Yellowhammer's identity" }
    }

    /// 2026-10-03T07:15:56Z
    private let instant = Date(timeIntervalSince1970: 1_791_011_756)

    @Test("A failing Act writes one `<ISO-8601 UTC> Error: <message>` line and keeps the exit code")
    func failureIsTimestamped() async {
        var lines: [String] = []
        var thrown: (any Error)?
        do {
            try await ActLog.reportingFailure(
                of: AuthorCommand.self, now: { instant },
                write: { text, date in lines.append(ActLog.line(text, at: date)) },
                body: { throw Refusal() }
            )
        } catch {
            thrown = error
        }

        #expect(lines == ["2026-10-03T07:15:56Z Error: the board refused Yellowhammer's identity"])
        #expect(thrown as? ExitCode == AuthorCommand.exitCode(for: Refusal()))
        #expect(thrown as? ExitCode != .success)
    }

    @Test("A Lease stand-down writes one `Stood down:` line, never `Error:`, and keeps the exit code")
    func standDownIsNotAnError() async throws {
        let directory = ConfigurationDirectory()
        let projectID = try #require(ProjectID(rawValue: "alpha"))
        let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)
        guard case .claimed(let holder) = try journal.claimActLease(act: .build, runID: RunID(), mode: .real) else {
            Issue.record("The running Act did not claim the Project")
            return
        }
        let standDown = EngineInvocationError.actLeaseHeld(act: .land, projectID: projectID, by: holder)

        var lines: [String] = []
        var thrown: (any Error)?
        do {
            try await ActLog.reportingFailure(
                of: LandCommand.self, now: { instant },
                write: { text, date in lines.append(ActLog.line(text, at: date)) },
                body: { throw standDown }
            )
        } catch {
            thrown = error
        }

        #expect(lines == ["2026-10-03T07:15:56Z Stood down: \(String(describing: standDown))"])
        #expect(lines.allSatisfy { !$0.contains("Error:") })
        #expect(thrown as? ExitCode == LandCommand.exitCode(for: standDown))
        #expect(thrown as? ExitCode != .success)
    }

    @Test("A validation failure keeps its non-default exit code")
    func validationExitCodeKept() async {
        var thrown: (any Error)?
        do {
            try await ActLog.reportingFailure(
                of: LandCommand.self, now: { instant }, write: { _, _ in },
                body: { throw ValidationError("bad") }
            )
        } catch {
            thrown = error
        }

        #expect(thrown as? ExitCode == LandCommand.exitCode(for: ValidationError("bad")))
    }

    @Test("A clean exit passes through and writes nothing")
    func cleanExitUntouched() async throws {
        var lines: [String] = []
        await #expect(throws: CleanExit.self) {
            try await ActLog.reportingFailure(
                of: BuildCommand.self, write: { text, _ in lines.append(text) }, body: { throw CleanExit.message("hi") }
            )
        }
        #expect(lines.isEmpty)
    }

    @Test("A line is the timestamp, one space, then the text")
    func lineFormat() {
        #expect(ActLog.line("stood down", at: instant) == "2026-10-03T07:15:56Z stood down")
    }

    @Test("A consumer reading the last log line still gets a timestamped line whole")
    func lastLineKeepsTimestamp() {
        let line = ActLog.line("Error: x", at: instant)
        #expect(line.hasSuffix("Error: x"))
        #expect(line.contains("Error:"))
    }

    @Test("A non-Act subcommand fails through ArgumentParser's own message, with no timestamp")
    func nonActOutputUnchanged() {
        let message = StatusCommand.fullMessage(for: Refusal())
        #expect(message == "Error: the board refused Yellowhammer's identity")
    }
}
