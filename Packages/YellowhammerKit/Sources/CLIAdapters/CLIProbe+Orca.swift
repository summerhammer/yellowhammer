import Darwin
import Domain
import Foundation

extension CLIProbe {
    func runOrcaProbe(
        adapter: some CLIAdapter, context: ProbeDispatchContext,
        dispatchA: Result<CLIRunReport, Error>, nonce: String, directSessionName: String
    ) async -> OrcaProbeFindings {
        var findings = await runOrcaTabProbe(adapter: adapter, context: context, nonce: nonce)
        if case .success(let report) = dispatchA, let session = report.session {
            let dispatch = context.dispatch(
                pass: .architect, family: .unattendedProbe, instruction: "",
                runDirectory: Self.unattendedRunDirectory(in: context), timeout: dispatchTimeout, resume: nil
            )
            findings.foreignTurnMarker = adapter.probeForeignTurnMarker(of: session, dispatch: dispatch)
            if let orcaAccess {
                let history = await orcaAccess.history(
                    adapter.cli, context.worktree.path, session.rawValue,
                    directSessionName, nonce
                )
                findings.sessionHistory = history.sessionHistory
                findings.sessionName = history.sessionName
            } else {
                findings.sessionHistory = .init(.notRun, detail: "Orca history observation is unavailable")
            }
        } else {
            findings.sessionHistory = .init(.notRun, detail: "direct dispatch produced no session to observe")
            findings.foreignTurnMarker = .init(.notRun, detail: "direct dispatch produced no session transcript")
        }
        return findings
    }

    private func runOrcaTabProbe(
        adapter: some CLIAdapter, context: ProbeDispatchContext, nonce: String
    ) async -> OrcaProbeFindings {
        var findings = OrcaProbeFindings()
        guard let workspace, let wrapperExecutable else {
            findings.tabRecognition = .init(.notRun, detail: "Orca tab host or pass wrapper is unavailable")
            return findings
        }
        var registration: RegistrationID?
        var worktree: WorkspaceWorktree?
        do {
            // The repo was made by this Probe, not selected from the Operator's registered Repos.
            registration = try await workspace.registerRepository(path: context.worktree.path)
            let created = try await workspace.createWorktree(
                repositoryPath: context.worktree.path, name: "yh-probe-visibility-\(Self.makeNonce())", baseBranch: nil
            )
            worktree = created
            findings = await exerciseTabClose(
                adapter: adapter, context: context, worktree: created,
                workspace: workspace, wrapperExecutable: wrapperExecutable, nonce: nonce
            )
        } catch {
            findings.tabRecognition = .init(.notRun, detail: "Orca Probe Worktree unavailable: \(error)")
        }
        // Cleanup must also run when the probing task is cancelled. Never remove the caller's Worktree.
        let cleanup = await Task {
            var failures: [String] = []
            if let worktree {
                do {
                    try await workspace.removeWorktree(id: worktree.id, force: true)
                } catch {
                    failures.append("Probe Worktree cleanup failed: \(error)")
                }
            }
            if let registration {
                do {
                    try await workspace.unregisterRepository(id: registration)
                } catch {
                    failures.append("Probe repository cleanup failed: \(error)")
                }
            }
            return failures
        }.value
        if !cleanup.isEmpty {
            findings.tabCloseContainment = .init(.failed, detail: cleanup.joined(separator: "; "))
        }
        return findings
    }

    // swiftlint:disable:next function_parameter_count function_body_length cyclomatic_complexity
    private func exerciseTabClose(
        adapter: some CLIAdapter, context: ProbeDispatchContext, worktree: WorkspaceWorktree,
        workspace: any Workspace, wrapperExecutable: String, nonce: String
    ) async -> OrcaProbeFindings {
        var findings = OrcaProbeFindings()
        let name = Self.sessionName(cli: adapter.cli, dispatch: "orca-tab")
        let tab = OrcaTabHost(workspace: workspace).session(worktreeID: worktree.id.rawValue, sessionName: name)
        let runDirectory = context.runsDirectory.appendingPathComponent("tab-close")
        let dispatch = context.dispatch(
            pass: .worker, family: .processContainmentProbe,
            instruction: Self.containmentInstruction(variant: "tabclose") + "\nDiagnostic token: \(nonce)",
            runDirectory: runDirectory, worktreePath: worktree.path, timeout: dispatchTimeout, resume: nil,
            sessionName: name
        )
        let runner = CLIRunner(
            process: AgentCLIProcess(
                gracePeriod: gracePeriod, pollInterval: pollInterval, wrapperExecutable: wrapperExecutable
            ), recorder: recorder
        )
        let box = OrcaProbeRunBox()
        let task = Task {
            do {
                let report = try await runner.run(
                    dispatch, adapter: adapter,
                    launcherStarter: { try await tab.startLauncher(launcherURL: $0) }
                )
                await box.finish(.success(report))
            } catch { await box.finish(.failure(error)) }
        }
        let holds = URL(filePath: worktree.path).appendingPathComponent(".yh-probe/holds-tabclose")
        let deadline = ContinuousClock.now + holdObservationTimeout
        var pids: [pid_t] = []
        while ContinuousClock.now < deadline, !Task.isCancelled {
            pids = Self.readPIDs(at: holds) ?? []
            let done = await box.isDone
            if pids.count >= 2 || done { break }
            try? await Task.sleep(for: pollInterval)
        }
        if pids.count >= 2, let orcaAccess, !Task.isCancelled {
            let observationDeadline = ContinuousClock.now + .seconds(5)
            repeat {
                findings = await orcaAccess.tab(adapter.cli, worktree, name, nonce)
                if findings.tabRecognition.finding == .passed && findings.hookTraffic.finding == .passed { break }
                try? await Task.sleep(for: pollInterval)
            } while ContinuousClock.now < observationDeadline && !Task.isCancelled
        }
        // Close the tab before cancelling the runner: only then can the wrapper's signal be attributed
        // to the tab close. The runner's existing timeout/abort fence still owns descendant cleanup.
        let closeFailure = await tab.closeReportingFailure()
        let closeDeadline = ContinuousClock.now + gracePeriod + .seconds(3)
        while !(await box.isDone), ContinuousClock.now < closeDeadline, !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
        }
        let completedAfterClose = await box.isDone
        task.cancel()
        await task.value
        // Creation can finish after the observation bound or cancellation. Once the runner has
        // joined, its starter cannot publish another tab, so this closes any late-created handle.
        let finalCloseFailure = await tab.closeReportingFailure()
        if pids.count < 2 {
            findings.tabCloseContainment = .init(.notRun, detail: "tab pass never produced the hold-tool processes")
        } else if case .success(let report) = await box.result {
            let survivors = Set(pids + report.leftovers.map(\.pid)).filter { !Self.isDead($0) }
            let passed = completedAfterClose && !report.engineSignalled && report.receivedSignals.contains(SIGTERM)
                && survivors.isEmpty
            findings.tabCloseContainment = .init(passed ? .passed : .failed, detail: passed
                ? "tab close reached the wrapper as SIGTERM; the CLI and hold-tool descendants ended"
                : "tab close did not confirm SIGTERM delivery and containment; known behaviour retained")
            for pid in survivors { kill(pid, SIGKILL) }
        } else {
            findings.tabCloseContainment = .init(.notRun, detail: "tab dispatch did not yield wrapper evidence")
        }
        if let closeFailure = closeFailure ?? finalCloseFailure {
            findings.tabCloseContainment = .init(.failed, detail: "tab close failed: \(closeFailure)")
        }
        return findings
    }
}

private actor OrcaProbeRunBox {
    private(set) var result: Result<CLIRunReport, Error>?
    var isDone: Bool { result != nil }
    func finish(_ result: Result<CLIRunReport, Error>) { self.result = result }
}
