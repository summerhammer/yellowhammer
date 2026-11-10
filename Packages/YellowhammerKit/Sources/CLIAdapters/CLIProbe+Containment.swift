import Darwin
import Domain
import Foundation

/// One containment variant (SIGTERM or SIGKILL): dispatches a worker pass told to run the hold
/// script in the foreground, observes its two pids, cancels the dispatch (the engine abort path),
/// and confirms nothing from it survives.
extension CLIProbe {
    enum ContainmentHost {
        case directSpawn
        case orcaTab(tabHost: OrcaTabHost, worktree: WorkspaceWorktree)

        var displayName: String {
            switch self {
            case .directSpawn: "direct spawn"
            case .orcaTab: "Orca tab host"
            }
        }

        var directoryPrefix: String {
            switch self {
            case .directSpawn: "direct"
            case .orcaTab: "tab"
            }
        }
    }

    // Runs both containment variants on direct spawn and, when Workspace is available, Orca tab host.
    // Combines them into one finding: passed iff all exercised variants on both hosts pass.
    func runContainment(
        adapter: some CLIAdapter, context: ProbeDispatchContext
    ) async -> (ProbeFinding, String?) {
        let (directSigtermFinding, directSigtermDetail) = await runContainmentVariant(
            "sigterm",
            host: .directSpawn,
            adapter: adapter,
            context: context,
            gracePeriod: gracePeriod
        )
        let (directSigkillFinding, directSigkillDetail) = await runContainmentVariant(
            "sigkill",
            host: .directSpawn,
            adapter: adapter,
            context: context,
            gracePeriod: .zero
        )

        var allFindings = [directSigtermFinding, directSigkillFinding]
        var allDetails = [directSigtermDetail, directSigkillDetail].compactMap { $0 }

        if let workspace {
            let (tabFindings, tabDetails) = await runOrcaTabContainment(
                workspace: workspace,
                adapter: adapter,
                context: context
            )
            allFindings.append(contentsOf: tabFindings)
            allDetails.append(contentsOf: tabDetails)
        }

        let finding: ProbeFinding = allFindings.allSatisfy { $0 == .passed } ? .passed : .failed
        let detail = allDetails.isEmpty ? nil : allDetails.joined(separator: "; ")
        return (finding, detail)
    }

    private func runOrcaTabContainment(
        workspace: any Workspace,
        adapter: some CLIAdapter,
        context: ProbeDispatchContext
    ) async -> ([ProbeFinding], [String]) {
        var findings: [ProbeFinding] = []
        var details: [String] = []
        var registrationID: RegistrationID?
        var orcaWorktree: WorkspaceWorktree?
        defer {
            if let orcaWorktree {
                _ = try? await workspace.removeWorktree(id: orcaWorktree.id, force: true)
            }
            if let registrationID {
                _ = try? await workspace.unregisterRepository(id: registrationID)
            }
        }

        do {
            let regID = try await workspace.registerRepository(path: context.worktree.path)
            registrationID = regID

            let worktreeName = "yh-probe-\(Self.makeNonce())"
            let worktree = try await workspace.createWorktree(
                repositoryPath: context.worktree.path,
                name: worktreeName,
                baseBranch: nil
            )
            orcaWorktree = worktree

            prepareHoldScript(in: worktree)

            let tabHost = OrcaTabHost(workspace: workspace)
            let (tabFindings, tabDetails) = await runTabVariants(
                tabHost: tabHost,
                worktree: worktree,
                adapter: adapter,
                context: context
            )
            findings.append(contentsOf: tabFindings)
            details.append(contentsOf: tabDetails)
        } catch let error {
            switch error {
            case .unavailable(let reason):
                details.append("Orca tab host not exercised: \(reason)")
            default:
                findings.append(.failed)
                details.append("Orca tab host: \(error.description)")
            }
        }
        return (findings, details)
    }

    private func runTabVariants(
        tabHost: OrcaTabHost,
        worktree: WorkspaceWorktree,
        adapter: some CLIAdapter,
        context: ProbeDispatchContext
    ) async -> ([ProbeFinding], [String]) {
        var findings: [ProbeFinding] = []
        var details: [String] = []

        let (sigtermFinding, sigtermDetail) = await runContainmentVariant(
            "sigterm",
            host: .orcaTab(tabHost: tabHost, worktree: worktree),
            adapter: adapter,
            context: context,
            gracePeriod: gracePeriod
        )
        findings.append(sigtermFinding)
        if let detail = sigtermDetail { details.append(detail) }

        let isUnreachable = sigtermDetail?.contains("Orca tab host not exercised") == true
        if !isUnreachable {
            let (sigkillFinding, sigkillDetail) = await runContainmentVariant(
                "sigkill",
                host: .orcaTab(tabHost: tabHost, worktree: worktree),
                adapter: adapter,
                context: context,
                gracePeriod: .zero
            )
            findings.append(sigkillFinding)
            if let detail = sigkillDetail { details.append(detail) }
        }
        return (findings, details)
    }

    private func prepareHoldScript(in worktree: WorkspaceWorktree) {
        let holdScript = URL(fileURLWithPath: worktree.path)
            .appendingPathComponent(DiagnosticInstruction.holdScriptName)
        if !FileManager.default.fileExists(atPath: holdScript.path) {
            try? Self.holdScriptContents.write(to: holdScript, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: holdScript.path)
        }
    }

    private func makeLauncherStarter(for tabSession: OrcaTabHost.TabSession?) -> CLIRunner.LauncherStarter? {
        guard let tabSession else { return nil }
        return { launcherURL in try await tabSession.startLauncher(launcherURL: launcherURL) }
    }

    private func makeTabObserver(for tabSession: OrcaTabHost.TabSession?) -> CLIRunner.TabObserver? {
        guard let tabSession else { return nil }
        return { await tabSession.observeTabGone() }
    }

    private func resolveHost(
        _ host: ContainmentHost,
        variant: String,
        context: ProbeDispatchContext
    ) -> (URL, OrcaTabHost.TabSession?) {
        switch host {
        case .directSpawn:
            return (context.worktree, nil)
        case .orcaTab(let tabHost, let worktree):
            let session = tabHost.session(worktreeID: worktree.id.rawValue, sessionName: "probe-\(variant)")
            return (URL(fileURLWithPath: worktree.path), session)
        }
    }

    private func executeContainmentDispatch(
        dispatch: CLIDispatch,
        variant: String,
        adapter: some CLIAdapter,
        gracePeriod: Duration,
        tabSession: OrcaTabHost.TabSession?
    ) async -> ([pid_t], Result<CLIRunReport, Error>?) {
        let runner = CLIRunner(
            process: AgentCLIProcess(
                gracePeriod: gracePeriod,
                pollInterval: pollInterval,
                wrapperExecutable: wrapperExecutable ?? CommandLine.arguments.first ?? "yh"
            ),
            recorder: recorder
        )
        let launcherStarter = makeLauncherStarter(for: tabSession)
        let tabObserver = makeTabObserver(for: tabSession)
        let box = ContainmentBox()
        let dispatchTask = Task {
            do {
                let report = try await runner.run(
                    dispatch,
                    adapter: adapter,
                    launcherStarter: launcherStarter,
                    tabObserver: tabObserver
                )
                await box.set(.success(report))
            } catch {
                await box.set(.failure(error))
            }
        }

        let worktreePath = dispatch.worktreePath
        let holdsFile = URL(fileURLWithPath: worktreePath).appendingPathComponent(".yh-probe/holds-\(variant)")
        let pids = await observeHoldPIDs(at: holdsFile, box: box)
        dispatchTask.cancel()
        _ = await dispatchTask.value
        await tabSession?.close()

        let dispatchResult = await box.result
        return (pids, dispatchResult)
    }

    func runContainmentVariant(
        _ variant: String,
        host: ContainmentHost,
        adapter: some CLIAdapter,
        context: ProbeDispatchContext,
        gracePeriod: Duration
    ) async -> (ProbeFinding, String?) {
        let runDirectory = context.runsDirectory.appendingPathComponent("\(host.directoryPrefix)-\(variant)")
        let (worktreeURL, tabSession) = resolveHost(host, variant: variant, context: context)

        let dispatch = context.dispatch(
            pass: .worker,
            family: .processContainmentProbe,
            instruction: Self.containmentInstruction(variant: variant),
            runDirectory: runDirectory,
            worktreePath: worktreeURL.path,
            timeout: dispatchTimeout,
            resume: nil
        )

        let (pids, dispatchResult) = await executeContainmentDispatch(
            dispatch: dispatch,
            variant: variant,
            adapter: adapter,
            gracePeriod: gracePeriod,
            tabSession: tabSession
        )

        let holdPGID: pid_t? = pids.first.map { getpgid($0) }
        let holdAncestry: [pid_t] = pids.first.map { ProcessTree.ancestors(of: $0) } ?? []

        let leaderPID: pid_t? = {
            guard case .success(let report) = dispatchResult else { return nil }
            return report.pid
        }()

        if case .failure(let error as WorkspaceError) = dispatchResult,
           case .unavailable(let reason) = error {
            return (.passed, "Orca tab host not exercised: \(reason)")
        }

        guard pids.count >= 2 else {
            let desc = Self.describe(dispatchResult)
            return (.failed, "\(host.displayName) \(variant): tool subprocess never observed; \(desc)")
        }

        let survivors = await Self.awaitDeath(of: pids, within: .seconds(2), pollInterval: pollInterval)
        guard !survivors.isEmpty else { return (.passed, nil) }

        // The probe never leaves orphans behind: SIGKILL every survivor directly (by pid, not by
        // group — that is exactly what it just escaped), then confirm death before returning.
        for pid in survivors { kill(pid, SIGKILL) }
        _ = await Self.awaitDeath(of: survivors, within: .seconds(1), pollInterval: pollInterval)

        let reason = Self.containmentFailureReason(
            target: "\(host.displayName) \(variant)",
            survivors: survivors,
            holdPGID: holdPGID,
            leaderPID: leaderPID,
            ancestry: holdAncestry
        )
        return (.failed, reason)
    }

    /// Explains why a survivor escaped containment, now that the abort path's descendant sweep
    /// (`AgentCLIProcess+Termination.swift`) reaches every process group escape: the only way a
    /// survivor remains is that it was NOT a descendant of the CLI leader when the dispatch was
    /// aborted — `ancestry` (the hold pid's parent chain, captured before cancelling) is what tells
    /// that apart from the sweep itself failing to reach a process that WAS still a descendant.
    private static func containmentFailureReason(
        target: String, survivors: [pid_t], holdPGID: pid_t?, leaderPID: pid_t?, ancestry: [pid_t]
    ) -> String {
        let pgidText = holdPGID.map(String.init) ?? "unknown"
        guard let leaderPID else {
            return "\(target): pids \(survivors) (process group \(pgidText)) outlived the abort path"
        }
        if ancestry.contains(leaderPID) {
            return "\(target): tool subprocess pids \(survivors) (process group \(pgidText)) were descendants "
                + "of the CLI (pid \(leaderPID)) but outlived the abort path"
        }
        return "\(target): tool subprocess pids \(survivors) (process group \(pgidText)) were not descendants "
            + "of the CLI (pid \(leaderPID)) when the dispatch was aborted, so the abort path could not reach them"
    }

    private func observeHoldPIDs(at holdsFile: URL, box: ContainmentBox) async -> [pid_t] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: holdObservationTimeout)
        var pids: [pid_t] = Self.readPIDs(at: holdsFile) ?? []
        while pids.count < 2, clock.now < deadline {
            if await box.isDone { break }
            try? await Task.sleep(for: pollInterval)
            pids = Self.readPIDs(at: holdsFile) ?? []
        }
        return pids
    }

    /// Polls until every pid in `pids` is dead or `timeout` elapses. Returns whichever are still
    /// alive at that point (empty when all died).
    private static func awaitDeath(
        of pids: [pid_t], within timeout: Duration, pollInterval: Duration
    ) async -> [pid_t] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var alive = pids.filter { !isDead($0) }
        while !alive.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            alive = alive.filter { !isDead($0) }
        }
        return alive
    }

    static func containmentInstruction(variant: String) -> String {
        DiagnosticInstruction.containment(variant: variant)
    }

    private actor ContainmentBox {
        private(set) var result: Result<CLIRunReport, Error>?
        func set(_ result: Result<CLIRunReport, Error>) { self.result = result }
        var isDone: Bool { result != nil }
    }

    private static func describe(_ result: Result<CLIRunReport, Error>?) -> String {
        switch result {
        case nil:
            "dispatch did not finish"
        case .failure(let error):
            "\(error)"
        case .success(let report):
            "\(report.end)"
        }
    }

    static func readPIDs(at url: URL) -> [pid_t]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let pids = text.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        return pids.isEmpty ? nil : pids
    }

    static func isDead(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }
}
