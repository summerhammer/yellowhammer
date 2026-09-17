import Darwin
import Domain
import Foundation

/// One containment variant (SIGTERM or SIGKILL): dispatches a worker pass told to run the hold
/// script in the foreground, observes its two pids, cancels the dispatch (the engine abort path),
/// and confirms nothing from it survives.
extension CLIProbe {
    // swiftlint:disable:next function_parameter_count
    func runContainmentVariant(
        _ variant: String,
        adapter: some CLIAdapter,
        route: Route,
        executable: String,
        environment: [String: String],
        worktree: URL,
        runsDirectory: URL,
        gracePeriod: Duration
    ) async -> (ProbeFinding, String?) {
        let runDirectory = runsDirectory.appendingPathComponent(variant)
        let dispatch = CLIDispatch(
            route: route,
            pass: .worker,
            instruction: Self.containmentInstruction(variant: variant),
            worktreePath: worktree.path,
            runDirectory: runDirectory,
            timeout: dispatchTimeout,
            resume: nil,
            additionalWritableDirectories: [],
            executable: executable,
            environment: environment
        )
        let runner = CLIRunner(process: AgentCLIProcess(gracePeriod: gracePeriod, pollInterval: pollInterval))

        let box = ContainmentBox()
        let dispatchTask = Task {
            do {
                let report = try await runner.run(dispatch, adapter: adapter)
                await box.set(.success(report))
            } catch {
                await box.set(.failure(error))
            }
        }

        let holdsFile = worktree.appendingPathComponent(".yh-probe/holds-\(variant)")
        let pids = await observeHoldPIDs(at: holdsFile, box: box)

        // Record the hold pids' actual process group before cancelling. This is NOT assumed equal
        // to the CLI leader's pid: a tool's shell command can run in a new process group of its own
        // (observed for real with claude's Bash tool), which is exactly the escape this probe target
        // exists to catch — so the leader pid is captured separately, from the run report itself.
        let holdPGID: pid_t? = pids.first.map { getpgid($0) }

        dispatchTask.cancel()
        _ = await dispatchTask.value
        let dispatchResult = await box.result
        let leaderPID: pid_t? = {
            guard case .success(let report) = dispatchResult else { return nil }
            return report.pid
        }()

        guard pids.count >= 2 else {
            return (.failed, "\(variant): tool subprocess never observed; \(Self.describe(dispatchResult))")
        }

        let survivors = await Self.awaitDeath(of: pids, within: .seconds(2), pollInterval: pollInterval)
        guard !survivors.isEmpty else { return (.passed, nil) }

        // The probe never leaves orphans behind: SIGKILL every survivor directly (by pid, not by
        // group — that is exactly what it just escaped), then confirm death before returning.
        for pid in survivors { kill(pid, SIGKILL) }
        _ = await Self.awaitDeath(of: survivors, within: .seconds(1), pollInterval: pollInterval)

        let reason = Self.containmentFailureReason(
            variant: variant, survivors: survivors, holdPGID: holdPGID, leaderPID: leaderPID
        )
        return (.failed, reason)
    }

    /// Names the leader pid and the survivors' actual process group. When they differ, says so
    /// explicitly: the tool ran its subprocess outside the CLI's process group, so the group
    /// SIGKILL never reached it.
    private static func containmentFailureReason(
        variant: String, survivors: [pid_t], holdPGID: pid_t?, leaderPID: pid_t?
    ) -> String {
        let pgidText = holdPGID.map(String.init) ?? "unknown"
        if let holdPGID, let leaderPID, holdPGID != leaderPID {
            return "\(variant): tool subprocess pids \(survivors) ran in process group \(holdPGID), "
                + "outside the CLI's process group \(leaderPID), and outlived its SIGKILL"
        }
        let leaderText = leaderPID.map(String.init) ?? pgidText
        return "\(variant): pids \(survivors) (pgid \(pgidText)) outlived the process group \(leaderText)"
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
        """
        This is an automated Yellowhammer probe, not real work. Using your shell tool, run exactly \
        the command `sh yh-probe-hold.sh \(variant)` in the foreground from the current working \
        directory, and wait for it to finish. Do nothing else.
        """
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
