import ArgumentParser
import Config
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
        stateContainment: .failed,
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
    #expect(result.findingStateContainment == .failed)
    #expect(result.reason == "sigterm: outlived the process group")
    #expect(result.verdict == .failed)
}

@Test("A failed state containment is recorded but leaves a passing verdict alone")
func probeRecordingStateContainmentDoesNotGate() {
    let result = ProbeRecording.probeResult(
        cli: "agy", probedAt: Date(timeIntervalSince1970: 1_800_000_000), adapterVersion: "1", cliVersion: "1",
        unattendedDispatch: .passed, resultFileOnCleanExit: .passed, processContainment: .passed,
        sessionResumption: .passed, stateContainment: .failed, reason: "state containment: config readable"
    )

    #expect(result.findingStateContainment == .failed)
    #expect(result.verdict == .passed)
    #expect(!ProbeCommand.everyFindingPassed(result))
}

// MARK: - Report

@Test("The printed report has a state containment line between session resumption and the verdict")
func reportPrintsStateContainment() throws {
    let result = ProbeRecording.probeResult(
        cli: "codex", probedAt: Date(timeIntervalSince1970: 1_800_000_000), adapterVersion: "3", cliVersion: "1",
        unattendedDispatch: .passed, resultFileOnCleanExit: .passed, processContainment: .passed,
        sessionResumption: .passed, stateContainment: .passed, reason: nil
    )

    let lines = ProbeCommand.reportLines(result, drift: nil)

    let index = try #require(lines.firstIndex(of: "state containment: passed"))
    #expect(lines[index - 1] == "session resumption: passed")
    #expect(lines[index + 1] == "verdict: passed")
    #expect(ProbeCommand.everyFindingPassed(result))
}

@Test("A state containment regression is named in the printed drift line")
func reportNamesStateContainmentDrift() throws {
    let previous = ProbeRecording.probeResult(
        cli: "claude", probedAt: Date(timeIntervalSince1970: 1_800_000_000), adapterVersion: "1", cliVersion: "1",
        unattendedDispatch: .passed, resultFileOnCleanExit: .passed, processContainment: .passed,
        sessionResumption: .passed, stateContainment: .passed, reason: nil
    )
    let current = ProbeRecording.probeResult(
        cli: "claude", probedAt: Date(timeIntervalSince1970: 1_800_000_100), adapterVersion: "1", cliVersion: "2",
        unattendedDispatch: .passed, resultFileOnCleanExit: .passed, processContainment: .passed,
        sessionResumption: .passed, stateContainment: .failed, reason: "state containment: keychain readable"
    )

    let lines = ProbeCommand.reportLines(current, drift: current.drift(since: previous))

    #expect(lines.contains("state containment: failed"))
    let driftLine = try #require(lines.last)
    #expect(driftLine.hasPrefix("drift since the previous probe"))
    #expect(driftLine.hasSuffix(": state containment"))
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

@Test("RootCommand parses `probe --all` and `probe -a`")
func rootCommandParsesProbeAll() throws {
    let parsedLong = try RootCommand.parseAsRoot(["probe", "--all"])
    let probeLong = try #require(parsedLong as? ProbeCommand)
    #expect(probeLong.cli == nil)
    #expect(probeLong.all == true)

    let parsedShort = try RootCommand.parseAsRoot(["probe", "-a"])
    let probeShort = try #require(parsedShort as? ProbeCommand)
    #expect(probeShort.cli == nil)
    #expect(probeShort.all == true)
}

// MARK: - Probe Route (issue #577)

private func codexRoute(_ model: String, _ effort: String) -> Route {
    Route(cli: "codex", model: model, effort: effort)!
}

@Test("With no flags the probe uses the first base Routing Table Route naming the CLI")
func probeRouteComesFromRoutingTable() throws {
    let machine = MachineConfiguration(
        cliAdapters: [],
        routingTable: [
            RoutingEntry(kind: .any, route: Route(cli: "claude", model: "opus", effort: "high")!),
            RoutingEntry(
                kind: .any, route: Route(cli: "claude", model: "sonnet", effort: "low")!,
                fallbacks: [codexRoute("gpt-6.1-sol", "low")]
            )
        ]
    )
    let (route, source) = try ProbeCommand.resolveRoute(cli: "codex", model: nil, effort: nil, machine: machine)
    #expect(route == codexRoute("gpt-6.1-sol", "low"))
    #expect(source == .routingTable)
}

@Test("A flag wins over the Routing Table field it names, and the other field still comes from the table")
func probeRouteFlagsOverrideTable() throws {
    let machine = MachineConfiguration(
        cliAdapters: [], routingTable: [RoutingEntry(route: codexRoute("gpt-6.1-sol", "medium"))]
    )
    let partial = try ProbeCommand.resolveRoute(cli: "codex", model: "x", effort: nil, machine: machine)
    #expect(partial.route == codexRoute("x", "medium"))
    #expect(partial.source == .routingTable)
    let full = try ProbeCommand.resolveRoute(cli: "codex", model: "x", effort: "y", machine: machine)
    #expect(full.route == codexRoute("x", "y"))
    #expect(full.source == .flags)
}

@Test("With no Route naming the CLI, or no machine file, the built-in pair is probed")
func probeRouteFallsBackToBuiltInDefault() throws {
    let other = MachineConfiguration(
        cliAdapters: [], routingTable: [RoutingEntry(route: Route(cli: "claude", model: "opus", effort: "high")!)]
    )
    for machine in [other, nil] {
        let (route, source) = try ProbeCommand.resolveRoute(cli: "codex", model: nil, effort: nil, machine: machine)
        #expect(route == codexRoute("gpt-5.5", "low"))
        #expect(source == .builtInDefault)
    }
}

@Test("A CLI with no built-in pair and no table Route still needs --model")
func probeRouteUnknownCLINeedsModel() {
    #expect(throws: (any Error).self) {
        try ProbeCommand.resolveRoute(cli: "other", model: nil, effort: nil, machine: nil)
    }
}

@Test("The retry hint names the Route probed and the flags to retry with")
func probeRetryHintNamesRouteAndFlags() {
    let hint = ProbeCommand.retryHint(route: codexRoute("gpt-5.5", "low"), source: .builtInDefault)
    #expect(hint.contains("codex / gpt-5.5 / low"))
    #expect(hint.contains("--model"))
    #expect(hint.contains("--effort"))
}
