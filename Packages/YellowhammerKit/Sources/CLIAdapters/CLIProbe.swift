import Domain
import Foundation

/// Establishes, per agent CLI, the five things the spec requires before it may be offered as a
/// route target: unattended dispatch (no interactive auth/permission prompt), a schema-conforming
/// result file on clean exit, process-group containment under SIGTERM and SIGKILL, session
/// resumption, and (implicitly, via ``ProbeReport/cliVersion``) enough evidence for a later run to
/// detect drift. It also measures state containment: whether a read-only pass can reach the
/// Keychain, Yellowhammer's configuration directory or Linear (issue #557). Never throws — every
/// failure becomes a finding plus a sentence in ``ProbeReport/reason``, because a probe run must
/// always produce a Ledger row.
///
/// Split across extensions: this file only orchestrates; ``CLIProbe+Dispatch.swift`` builds and
/// classifies dispatch A/B, ``CLIProbe+Containment.swift`` runs the SIGTERM/SIGKILL variants,
/// ``CLIProbe+StateContainment.swift`` runs the reach script, and ``CLIProbe+Setup.swift`` holds
/// the Worktree/script/version-probe plumbing.
public struct CLIProbe: Sendable {
    public let dispatchTimeout: Duration
    public let holdObservationTimeout: Duration
    public let pollInterval: Duration
    public let gracePeriod: Duration
    /// Creates and deletes the throwaway Keychain item the state-containment dispatch tries to read.
    public let keychain: ProbeKeychain

    public init(
        dispatchTimeout: Duration = .seconds(300),
        holdObservationTimeout: Duration = .seconds(240),
        pollInterval: Duration = .milliseconds(100),
        gracePeriod: Duration = .seconds(3),
        keychain: ProbeKeychain = .login
    ) {
        self.dispatchTimeout = dispatchTimeout
        self.holdObservationTimeout = holdObservationTimeout
        self.pollInterval = pollInterval
        self.gracePeriod = gracePeriod
        self.keychain = keychain
    }

    /// - Parameter protectedDirectories: the directories no pass may read, exactly as a real dispatch
    ///   gets them (`CLIDispatch.protectedDirectories`): the configuration directory first, then the
    ///   Keychains directory. Every probe dispatch carries them, so a read-only probe pass is
    ///   contained the way a real one is, and the reach script checks the first one.
    public func run(
        adapter: some CLIAdapter,
        route: Route,
        executable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workDirectory: URL,
        protectedDirectories: [String]
    ) async -> ProbeReport {
        let worktree = workDirectory.appendingPathComponent("worktree")
        let context = ProbeDispatchContext(
            route: route, executable: executable, environment: environment, worktree: worktree,
            runsDirectory: workDirectory.appendingPathComponent("runs"), protectedDirectories: protectedDirectories
        )
        let reachTargets = ReachTargets(
            keychainAccount: Self.makeNonce(), configurationDirectory: protectedDirectories.first ?? ""
        )

        if let failure = await Self.setUp(
            worktree: worktree, adapter: adapter, workDirectory: workDirectory, reachTargets: reachTargets
        ) {
            return failure
        }

        let nonce = Self.makeNonce()
        let cliVersion = await Self.probeVersion(executable: executable, environment: environment)

        // Dispatch A — unattended dispatch + result file on clean exit.
        let unattendedRunDirectory = context.runsDirectory.appendingPathComponent("unattended")
        let dispatchA = await runDispatch(
            pass: .architect, adapter: adapter, context: context, runDirectory: unattendedRunDirectory,
            instruction: Self.unattendedInstruction(nonce: nonce), resume: nil
        )
        let (unattendedFinding, unattendedDetail) = Self.unattendedFinding(
            for: dispatchA, runDirectory: unattendedRunDirectory
        )
        let (resultFileFinding, resultFileDetail) = Self.resultFileFinding(for: dispatchA)

        // Dispatch B — session resumption.
        let (sessionResumptionFinding, sessionResumptionDetail) = await runSessionResumptionDispatch(
            adapter: adapter, context: context, dispatchA: dispatchA, nonce: nonce
        )

        // Containment — SIGTERM and SIGKILL.
        let (processContainmentFinding, containmentDetail) = await runContainment(adapter: adapter, context: context)

        // State containment — can the read-only shape reach the Keychain, the config or Linear?
        let (stateContainmentFinding, stateContainmentDetail) = await runStateContainment(
            adapter: adapter, context: context, keychainAccount: reachTargets.keychainAccount
        )

        let details = [
            unattendedDetail, resultFileDetail, containmentDetail, sessionResumptionDetail, stateContainmentDetail
        ].compactMap { $0 }
        let reason = details.isEmpty ? nil : details.joined(separator: "; ")

        return ProbeReport(
            cli: adapter.cli,
            adapterVersion: adapter.adapterVersion,
            cliVersion: cliVersion,
            unattendedDispatch: unattendedFinding,
            resultFileOnCleanExit: resultFileFinding,
            processContainment: processContainmentFinding,
            sessionResumption: sessionResumptionFinding,
            stateContainment: stateContainmentFinding,
            reason: reason,
            workDirectory: workDirectory
        )
    }

    // Runs both containment variants and combines them into one finding: passed iff both are.
    private func runContainment(
        adapter: some CLIAdapter, context: ProbeDispatchContext
    ) async -> (ProbeFinding, String?) {
        let (sigtermFinding, sigtermDetail) = await runContainmentVariant(
            "sigterm", adapter: adapter, context: context, gracePeriod: gracePeriod
        )
        let (sigkillFinding, sigkillDetail) = await runContainmentVariant(
            "sigkill", adapter: adapter, context: context, gracePeriod: .zero
        )
        let finding: ProbeFinding = (sigtermFinding == .passed && sigkillFinding == .passed) ? .passed : .failed
        let detail = [sigtermDetail, sigkillDetail].compactMap { $0 }.joined(separator: "; ")
        return (finding, detail.isEmpty ? nil : detail)
    }
}

/// What every dispatch of one probe run shares: the Route and executable under test, the Worktree
/// they run in, where their run directories go, and the directories no pass may read.
struct ProbeDispatchContext: Sendable {
    let route: Route
    let executable: String
    let environment: [String: String]
    let worktree: URL
    let runsDirectory: URL
    let protectedDirectories: [String]

    /// One probe dispatch, built the way the engine builds a real one, protected directories included.
    func dispatch(
        pass: RunPass, instruction: String, runDirectory: URL, timeout: Duration, resume: CLISession?
    ) -> CLIDispatch {
        CLIDispatch(
            route: route,
            pass: pass,
            instruction: instruction,
            worktreePath: worktree.path,
            runDirectory: runDirectory,
            timeout: timeout,
            resume: resume,
            additionalWritableDirectories: [],
            protectedDirectories: protectedDirectories,
            executable: executable,
            environment: environment
        )
    }
}
