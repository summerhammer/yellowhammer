import Domain
@testable import EngineCommand
import Foundation
import Ledger
import Testing

@Suite("Doctor: probes check")
struct DoctorProbesTests {
    private static let machineFileWithClaude = """
        [linear]
        credential = "keychain:linear"
        client_id = "yellowhammer-client-id"

        [github]
        credential = "keychain:github"

        [cli.claude]
        """

    @Test("An offered probe result passes")
    func offeredProbeResultPasses() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machineFileWithClaude)

        let store = try LedgerStore.open(configurationDirectory: directory.url)
        _ = try store.record(passingProbeResult(cli: "claude"))

        let doctor = makeDoctor(directory: directory, checks: [.configuration, .probes])
        let findings = await doctor.run()

        #expect(findings.contains { $0.check == .probes && $0.severity == .pass && $0.subject == "claude" })
    }

    @Test("A never-probed CLI fails")
    func neverProbedCLIFails() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machineFileWithClaude)

        let store = try LedgerStore.open(configurationDirectory: directory.url)
        _ = try store.record(passingProbeResult(cli: "codex"))

        let doctor = makeDoctor(directory: directory, checks: [.configuration, .probes])
        let findings = await doctor.run()

        #expect(findings.contains { $0.check == .probes && $0.severity == .failure && $0.subject == "claude" })
    }

    @Test("A missing Ledger fails every declared CLI, and doctor never creates the Ledger")
    func missingLedgerFailsWithoutCreating() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machineFileWithClaude)

        let doctor = makeDoctor(directory: directory, checks: [.configuration, .probes])
        let findings = await doctor.run()

        #expect(findings.contains { $0.check == .probes && $0.severity == .failure && $0.subject == "claude" })
        let ledgerURL = LedgerStore.defaultFileURL(configurationDirectory: directory.url)
        #expect(!FileManager.default.fileExists(atPath: ledgerURL.path(percentEncoded: false)))
    }

    @Test("--probe runs the probe seam for every declared CLI before reading eligibility")
    func probeFlagRunsProbeSeam() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machineFileWithClaude)

        final class Recorder: @unchecked Sendable {
            var names: [String] = []
        }
        let recorder = Recorder()

        let doctor = makeDoctor(
            directory: directory, runProbe: { name in recorder.names.append(name) },
            probe: true, checks: [.configuration, .probes]
        )
        _ = await doctor.run()

        #expect(recorder.names == ["claude"])
    }

    private func passingProbeResult(cli: String) -> ProbeResult {
        ProbeResult(
            cli: cli, probedAt: Date(), adapterVersion: "1", cliVersion: "1",
            findingResultFileOnCleanExit: .passed, findingUnattendedDispatch: .passed,
            findingProcessContainment: .passed, findingSessionResumption: .passed, reason: nil
        )
    }
}
