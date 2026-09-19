import Domain
import Foundation

/// Establishes, per agent CLI, the five things the spec requires before it may be offered as a
/// route target: unattended dispatch (no interactive auth/permission prompt), a schema-conforming
/// result file on clean exit, process-group containment under SIGTERM and SIGKILL, session
/// resumption, and (implicitly, via ``ProbeReport/cliVersion``) enough evidence for a later run to
/// detect drift. Never throws — every failure becomes a finding plus a sentence in
/// ``ProbeReport/reason``, because a probe run must always produce a Ledger row.
///
/// Split across extensions: this file only orchestrates; ``CLIProbe+Dispatch.swift`` builds and
/// classifies dispatch A/B, ``CLIProbe+Containment.swift`` runs the SIGTERM/SIGKILL variants, and
/// ``CLIProbe+Setup.swift`` holds the Worktree/hold-script/version-probe plumbing.
public struct CLIProbe: Sendable {
    public let dispatchTimeout: Duration
    public let holdObservationTimeout: Duration
    public let pollInterval: Duration
    public let gracePeriod: Duration

    public init(
        dispatchTimeout: Duration = .seconds(300),
        holdObservationTimeout: Duration = .seconds(240),
        pollInterval: Duration = .milliseconds(100),
        gracePeriod: Duration = .seconds(3)
    ) {
        self.dispatchTimeout = dispatchTimeout
        self.holdObservationTimeout = holdObservationTimeout
        self.pollInterval = pollInterval
        self.gracePeriod = gracePeriod
    }

    public func run(
        adapter: some CLIAdapter,
        route: Route,
        executable: String,
        environment: [String: String],
        workDirectory: URL
    ) async -> ProbeReport {
        let worktree = workDirectory.appendingPathComponent("worktree")
        let runsDirectory = workDirectory.appendingPathComponent("runs")

        if let failure = await Self.setUp(worktree: worktree, adapter: adapter, workDirectory: workDirectory) {
            return failure
        }

        let nonce = Self.makeNonce()
        let cliVersion = await Self.probeVersion(executable: executable, environment: environment)

        // Dispatch A — unattended dispatch + result file on clean exit.
        let unattendedRunDirectory = runsDirectory.appendingPathComponent("unattended")
        let dispatchA = await runDispatch(
            pass: .architect, adapter: adapter, route: route, executable: executable, environment: environment,
            worktree: worktree, runDirectory: unattendedRunDirectory,
            instruction: Self.unattendedInstruction(nonce: nonce), resume: nil
        )
        let (unattendedFinding, unattendedDetail) = Self.unattendedFinding(
            for: dispatchA, runDirectory: unattendedRunDirectory
        )
        let (resultFileFinding, resultFileDetail) = Self.resultFileFinding(for: dispatchA)

        // Dispatch B — session resumption.
        let (sessionResumptionFinding, sessionResumptionDetail) = await runSessionResumptionDispatch(
            adapter: adapter, route: route, executable: executable, environment: environment,
            worktree: worktree, runsDirectory: runsDirectory, dispatchA: dispatchA, nonce: nonce
        )

        // Containment — SIGTERM and SIGKILL.
        let (processContainmentFinding, containmentDetail) = await runContainment(
            adapter: adapter, route: route, executable: executable, environment: environment,
            worktree: worktree, runsDirectory: runsDirectory
        )

        let details = [unattendedDetail, resultFileDetail, containmentDetail, sessionResumptionDetail]
            .compactMap { $0 }
        let reason = details.isEmpty ? nil : details.joined(separator: "; ")

        return ProbeReport(
            cli: adapter.cli,
            adapterVersion: adapter.adapterVersion,
            cliVersion: cliVersion,
            unattendedDispatch: unattendedFinding,
            resultFileOnCleanExit: resultFileFinding,
            processContainment: processContainmentFinding,
            sessionResumption: sessionResumptionFinding,
            reason: reason,
            workDirectory: workDirectory
        )
    }

    // Runs both containment variants and combines them into one finding: passed iff both are.
    // swiftlint:disable:next function_parameter_count
    private func runContainment(
        adapter: some CLIAdapter,
        route: Route,
        executable: String,
        environment: [String: String],
        worktree: URL,
        runsDirectory: URL
    ) async -> (ProbeFinding, String?) {
        let (sigtermFinding, sigtermDetail) = await runContainmentVariant(
            "sigterm", adapter: adapter, route: route, executable: executable, environment: environment,
            worktree: worktree, runsDirectory: runsDirectory, gracePeriod: gracePeriod
        )
        let (sigkillFinding, sigkillDetail) = await runContainmentVariant(
            "sigkill", adapter: adapter, route: route, executable: executable, environment: environment,
            worktree: worktree, runsDirectory: runsDirectory, gracePeriod: .zero
        )
        let finding: ProbeFinding = (sigtermFinding == .passed && sigkillFinding == .passed) ? .passed : .failed
        let detail = [sigtermDetail, sigkillDetail].compactMap { $0 }.joined(separator: "; ")
        return (finding, detail.isEmpty ? nil : detail)
    }
}
