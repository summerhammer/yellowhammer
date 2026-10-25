import Darwin
@testable import CLIAdapters
import Domain
import Foundation
import Synchronization
import Testing

private final class MockPromptRecorder: DispatchPromptRecording, @unchecked Sendable {
    private struct State {
        var captured: [DispatchPromptRecord] = []
        var launches: [(launch: DispatchLaunch, record: DispatchPromptRecord)] = []
    }

    private let state = Mutex(State())

    var captured: [DispatchPromptRecord] {
        state.withLock { $0.captured }
    }

    var launches: [(launch: DispatchLaunch, record: DispatchPromptRecord)] {
        state.withLock { $0.launches }
    }

    func capture(_ record: DispatchPromptRecord) -> DispatchPromptCapture {
        state.withLock { $0.captured.append(record) }
        return .recorded(id: record.id)
    }

    func markLaunch(_ launch: DispatchLaunch, of record: DispatchPromptRecord) -> Bool {
        state.withLock { $0.launches.append((launch, record)) }
        return true
    }
}

@Suite("Diagnostic prompt recording: Probe and Route Pre-flight")
struct DiagnosticPromptRecordingTests {
    private static let route = Route(cli: "stub", model: "some-model", effort: "low")!
    private static let protectedDirectories = ["/Users/x/.config/yellowhammer", "/Users/x/Library/Keychains"]

    private func makeWorkDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-diag-prompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(_ script: String, in workDirectory: URL) throws -> String {
        let url = workDirectory.appendingPathComponent("cli-\(UUID().uuidString).sh")
        try StubProbeCLI.write(script, to: url)
        return url.path
    }

    @Test("A Probe run writes records with the right families, machine scope, and shared runID")
    func probeRunDiagnosticRecords() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.healthy, in: workDirectory)

        let recorder = MockPromptRecorder()
        let probe = CLIProbe(
            dispatchTimeout: .seconds(10),
            holdObservationTimeout: .seconds(10),
            pollInterval: .milliseconds(50),
            gracePeriod: .milliseconds(300),
            keychain: StubProbeKeychain().keychain,
            recorder: recorder
        )

        let report = await probe.run(
            adapter: StubProbeAdapter(),
            route: Self.route,
            executable: executable,
            environment: ProcessInfo.processInfo.environment,
            workDirectory: workDirectory,
            protectedDirectories: Self.protectedDirectories
        )

        #expect(report.unattendedDispatch == .passed)
        #expect(report.resultFileOnCleanExit == .passed)
        #expect(report.processContainment == .passed)
        #expect(report.sessionResumption == .passed)
        #expect(report.stateContainment == .passed)

        let captured = recorder.captured
        #expect(captured.count == 5)

        // All 5 must share the same non-nil runID and have nil projectID (machine scope)
        let firstRunID = try #require(captured.first?.provenance.runID)
        #expect(!firstRunID.isEmpty)

        for record in captured {
            #expect(record.provenance.runID == firstRunID)
            #expect(record.provenance.projectID == nil)
            #expect(record.provenance.scope == .machine)
        }

        let families = captured.map(\.provenance.family)
        #expect(families[0] == .unattendedProbe)
        #expect(families[1] == .sessionResumptionProbe)
        #expect(families[2] == .processContainmentProbe) // sigterm
        #expect(families[3] == .processContainmentProbe) // sigkill
        #expect(families[4] == .stateContainmentProbe)

        // Instructions unchanged
        #expect(captured[1].instruction == CLIProbe.resumeInstruction)
        #expect(captured[2].instruction == CLIProbe.containmentInstruction(variant: "sigterm"))
        #expect(captured[3].instruction == CLIProbe.containmentInstruction(variant: "sigkill"))
        #expect(captured[4].instruction == CLIProbe.stateContainmentInstruction)
    }

    @Test("A Route Pre-flight writes a prompt record with routePreflight family, Project scope, and given runID")
    func routePreflightDiagnosticRecord() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.healthy, in: workDirectory)

        let recorder = MockPromptRecorder()
        let preflight = CLIRoutePreflight(timeout: .seconds(10), recorder: recorder)

        let reason = await preflight.run(
            adapter: StubProbeAdapter(),
            route: Self.route,
            executable: executable,
            environment: ProcessInfo.processInfo.environment,
            workDirectory: workDirectory,
            projectID: "project-omega",
            runID: "act-run-777"
        )

        #expect(reason == nil)
        #expect(recorder.captured.count == 1)

        let record = try #require(recorder.captured.first)
        #expect(record.provenance.family == .routePreflight)
        #expect(record.provenance.projectID == "project-omega")
        #expect(record.provenance.runID == "act-run-777")
        #expect(record.provenance.scope == .project(ProjectID(rawValue: "project-omega")!))
        #expect(record.instruction.contains("This is an automated Yellowhammer probe, not real work."))
        #expect(record.instruction.contains("Do not read or modify any files and do not run any command."))
    }
}
