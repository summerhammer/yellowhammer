import ArgumentParser
import Domain
@testable import EngineCommand
import Foundation
import Ledger
import Testing

// MARK: - ProbeExecutable

@Test("A declared executable wins over any PATH search")
func declaredExecutableWins() {
    let resolved = ProbeExecutable.resolve(
        name: "claude", declared: "/opt/custom/claude", path: "/usr/bin:/usr/local/bin",
        fileExists: { _ in true }
    )
    #expect(resolved == "/opt/custom/claude")
}

@Test("With no declared executable, the first PATH entry containing it wins")
func pathFallbackFindsExecutable() {
    let resolved = ProbeExecutable.resolve(
        name: "codex", declared: nil, path: "/usr/bin:/usr/local/bin",
        fileExists: { $0 == "/usr/local/bin/codex" }
    )
    #expect(resolved == "/usr/local/bin/codex")
}

@Test("An empty declared executable falls through to the PATH search")
func emptyDeclaredExecutableFallsThrough() {
    let resolved = ProbeExecutable.resolve(
        name: "codex", declared: "", path: "/usr/local/bin",
        fileExists: { $0 == "/usr/local/bin/codex" }
    )
    #expect(resolved == "/usr/local/bin/codex")
}

@Test("Nothing declared and nothing on PATH resolves to nil")
func noExecutableResolvesToNil() {
    let resolved = ProbeExecutable.resolve(
        name: "claude", declared: nil, path: "/usr/bin:/usr/local/bin",
        fileExists: { _ in false }
    )
    #expect(resolved == nil)
}

@Test("A nil PATH with nothing declared resolves to nil")
func nilPathResolvesToNil() {
    let resolved = ProbeExecutable.resolve(name: "claude", declared: nil, path: nil, fileExists: { _ in true })
    #expect(resolved == nil)
}

// MARK: - ProbeRecording

@Test("ProbeRecording maps findings and strings into a Ledger ProbeResult")
func probeRecordingMapsFields() {
    let probedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let result = ProbeRecording.probeResult(
        cli: "claude",
        probedAt: probedAt,
        adapterVersion: "1",
        cliVersion: "2.3.4",
        unattendedDispatch: .passed,
        resultFileOnCleanExit: .passed,
        processContainment: .failed,
        sessionResumption: .notRun,
        reason: "sigterm: outlived the process group"
    )

    #expect(result.cli == "claude")
    #expect(result.probedAt == probedAt)
    #expect(result.adapterVersion == "1")
    #expect(result.cliVersion == "2.3.4")
    #expect(result.findingUnattendedDispatch == .passed)
    #expect(result.findingResultFileOnCleanExit == .passed)
    #expect(result.findingProcessContainment == .failed)
    #expect(result.findingSessionResumption == .notRun)
    #expect(result.reason == "sigterm: outlived the process group")
    #expect(result.verdict == .failed)
}

// MARK: - RootCommand parsing

@Test("RootCommand parses `probe claude --model x --effort y`")
func rootCommandParsesProbe() throws {
    let parsed = try RootCommand.parseAsRoot(["probe", "claude", "--model", "x", "--effort", "y"])
    let probe = try #require(parsed as? ProbeCommand)
    #expect(probe.cli == "claude")
    #expect(probe.model == "x")
    #expect(probe.effort == "y")
    #expect(probe.keep == false)
}

@Test("RootCommand parses `probe` without --model/--effort, deferring defaults to the command")
func rootCommandParsesProbeWithoutOptions() throws {
    let parsed = try RootCommand.parseAsRoot(["probe", "codex"])
    let probe = try #require(parsed as? ProbeCommand)
    #expect(probe.cli == "codex")
    #expect(probe.model == nil)
    #expect(probe.effort == nil)
}

@Test("RootCommand parses `probe --keep`")
func rootCommandParsesProbeKeep() throws {
    let parsed = try RootCommand.parseAsRoot(["probe", "claude", "--keep"])
    let probe = try #require(parsed as? ProbeCommand)
    #expect(probe.keep == true)
}
