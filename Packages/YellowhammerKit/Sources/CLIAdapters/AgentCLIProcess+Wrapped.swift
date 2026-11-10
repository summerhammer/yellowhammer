import Darwin
import Domain
import Foundation

extension AgentCLIProcess {
    /// Runs a pass through the wrapper launcher beside direct spawn.
    public func executeWrapped(
        _ launch: AgentCLILaunch,
        runDirectory: URL? = nil,
        wrapperExecutable: String? = nil,
        onSpawn: (@Sendable () -> Void)? = nil,
        tabObserver: (@Sendable () async -> Bool)? = nil,
        startLauncher: @Sendable (_ launcherURL: URL) async throws -> Void
    ) async throws -> AgentCLIExecution {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: launch.worktreePath, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw AgentCLILaunchError.worktreeMissing(launch.worktreePath)
        }

        let resolvedRunDir = runDirectory ?? launch.resultFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: resolvedRunDir, withIntermediateDirectories: true)

        let resolvedWrapper = wrapperExecutable ?? self.wrapperExecutable
        let specURL = resolvedRunDir.appendingPathComponent(PassWrapper.specFileName)
        let spec = PassWrapperSpec(launch: launch, runDirectory: resolvedRunDir)
        let startedURL = URL(fileURLWithPath: spec.startedPath)
        try? FileManager.default.removeItem(at: startedURL)
        let statusURL = URL(fileURLWithPath: spec.statusPath)
        try? FileManager.default.removeItem(at: statusURL)
        do {
            try spec.write(to: specURL)
        } catch {
            throw AgentCLILaunchError.spawnFailed(errno: EIO, executable: resolvedWrapper)
        }

        let launcherURL = resolvedRunDir.appendingPathComponent(PassLauncher.fileName)
        do {
            try PassLauncher.writeLauncher(
                to: launcherURL,
                wrapperExecutable: resolvedWrapper,
                specPath: specURL.path,
                addedEnvironment: launch.addedEnvironment
            )
        } catch {
            throw AgentCLILaunchError.spawnFailed(errno: EIO, executable: resolvedWrapper)
        }

        let promptWatch = await promptSource.start()

        var dispatchedAtTV = timeval()
        gettimeofday(&dispatchedAtTV, nil)
        let dispatchedAt = ProcessStartTime(
            seconds: UInt64(dispatchedAtTV.tv_sec), microseconds: UInt64(dispatchedAtTV.tv_usec)
        )

        do {
            try await startLauncher(launcherURL)
        } catch {
            await promptWatch?.stop()
            throw error
        }

        guard let started = await waitForStarted(at: startedURL, timeout: startTimeout) else {
            await promptWatch?.stop()
            let tabGone = if let tabObserver {
                await tabObserver()
            } else {
                nil as Bool?
            }
            let end = RunEnd.crashedUnknown(.wrapperRecordMissing("wrapper never reported a started CLI"))
            let snapshot = RunningSnapshot(
                dispatchedAt: dispatchedAt, processes: [], processGroups: [], sessions: []
            )
            return AgentCLIExecution(
                pid: 0, processGroup: 0, end: end, leftovers: [], snapshot: snapshot,
                engineSignalled: false, receivedSignals: [], tabGone: tabGone
            )
        }

        onSpawn?()

        let result = await waitWrapped(
            started: started,
            statusURL: statusURL,
            timeout: launch.timeout,
            dispatchedAt: dispatchedAt,
            promptWatch: promptWatch
        )
        await promptWatch?.stop()
        let tabGone = if let tabObserver {
            await tabObserver()
        } else {
            nil as Bool?
        }
        return AgentCLIExecution(
            pid: started.pid,
            processGroup: started.processGroup,
            end: result.end,
            leftovers: result.leftovers,
            snapshot: result.snapshot,
            engineSignalled: result.engineSignalled,
            receivedSignals: result.receivedSignals,
            tabGone: tabGone
        )
    }

    public func runWrapped(
        _ launch: AgentCLILaunch,
        runDirectory: URL? = nil,
        wrapperExecutable: String? = nil,
        tabObserver: (@Sendable () async -> Bool)? = nil,
        startLauncher: @Sendable (_ launcherURL: URL) async throws -> Void
    ) async throws -> AgentCLIRunReport {
        let execution = try await executeWrapped(
            launch,
            runDirectory: runDirectory,
            wrapperExecutable: wrapperExecutable,
            tabObserver: tabObserver,
            startLauncher: startLauncher
        )
        let outcome = RunOutcome.classify(end: execution.end, resultFileAt: launch.resultFile, pass: launch.pass)
        return AgentCLIRunReport(
            pid: execution.pid,
            processGroup: execution.processGroup,
            end: execution.end,
            outcome: outcome,
            leftovers: execution.leftovers,
            snapshot: execution.snapshot,
            engineSignalled: execution.engineSignalled,
            receivedSignals: execution.receivedSignals,
            tabGone: execution.tabGone
        )
    }

    private func waitWrapped(
        started: PassWrapperStarted,
        statusURL: URL,
        timeout: Duration,
        dispatchedAt: ProcessStartTime,
        promptWatch: (any PromptWatching)?
    ) async -> WaitResult {
        let clock = ContinuousClock()
        let start = clock.now
        var tracked = Set<ProcessTree.TrackedProcess>()
        var lastSnapshot: ContinuousClock.Instant?

        func snapshot() -> RunningSnapshot {
            Self.makeSnapshot(
                leaderPID: started.pid,
                leaderSession: started.session,
                dispatchedAt: dispatchedAt,
                tracked: tracked
            )
        }

        while true {
            if lastSnapshot == nil || clock.now - lastSnapshot! >= snapshotInterval {
                tracked.formUnion(ProcessTree.descendants(of: started.pid))
                lastSnapshot = clock.now
            }
            if !Self.isAlive(pid: started.pid, started: started) {
                let statusRecord = await Self.readStatus(
                    at: statusURL, timeout: statusTimeout, pollInterval: pollInterval
                )
                let end: RunEnd
                if let statusRecord {
                    if let exitStatus = statusRecord.exitStatus {
                        end = .exited(status: exitStatus)
                    } else if let signal = statusRecord.signal {
                        end = .signaled(signal)
                    } else {
                        end = .crashedUnknown(
                            .wrapperRecordMissing("wrapper-status.json contained neither exitStatus nor signal")
                        )
                    }
                } else {
                    end = .crashedUnknown(.wrapperRecordMissing("missing or unreadable wrapper-status.json"))
                }
                let leftovers = await sweepAfterExit(tracked: tracked)
                return WaitResult(
                    end: end,
                    leftovers: leftovers,
                    snapshot: snapshot(),
                    engineSignalled: false,
                    receivedSignals: statusRecord?.receivedSignals ?? []
                )
            }
            if let promptWatch,
               let prompt = await Self.attributedPrompt(in: promptWatch, leaderPID: started.pid, tracked: &tracked) {
                let end = await terminate(
                    pid: started.pid,
                    leaderIdentity: started,
                    reason: .permissionPrompt(prompt.detail)
                )
                let statusRecord = await Self.readStatus(
                    at: statusURL, timeout: .milliseconds(500), pollInterval: pollInterval
                )
                return WaitResult(
                    end: end,
                    leftovers: [],
                    snapshot: snapshot(),
                    engineSignalled: true,
                    receivedSignals: statusRecord?.receivedSignals ?? []
                )
            }
            if Task.isCancelled {
                let end = await terminate(
                    pid: started.pid,
                    leaderIdentity: started,
                    reason: .aborted
                )
                let statusRecord = await Self.readStatus(
                    at: statusURL, timeout: .milliseconds(500), pollInterval: pollInterval
                )
                return WaitResult(
                    end: end,
                    leftovers: [],
                    snapshot: snapshot(),
                    engineSignalled: true,
                    receivedSignals: statusRecord?.receivedSignals ?? []
                )
            }
            if clock.now - start >= timeout {
                let end = await terminate(
                    pid: started.pid,
                    leaderIdentity: started,
                    reason: .timedOut(after: timeout)
                )
                let statusRecord = await Self.readStatus(
                    at: statusURL, timeout: .milliseconds(500), pollInterval: pollInterval
                )
                return WaitResult(
                    end: end,
                    leftovers: [],
                    snapshot: snapshot(),
                    engineSignalled: true,
                    receivedSignals: statusRecord?.receivedSignals ?? []
                )
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func waitForStarted(at url: URL, timeout: Duration) async -> PassWrapperStarted? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let decoder = JSONDecoder()

        while clock.now < deadline {
            if let data = try? Data(contentsOf: url),
               let started = try? decoder.decode(PassWrapperStarted.self, from: data) {
                return started
            }
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: pollInterval)
        }
        if let data = try? Data(contentsOf: url),
           let started = try? decoder.decode(PassWrapperStarted.self, from: data) {
            return started
        }
        return nil
    }

    private static func readStatus(
        at url: URL,
        timeout: Duration,
        pollInterval: Duration
    ) async -> PassWrapperStatus? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let decoder = JSONDecoder()

        while clock.now < deadline {
            if let data = try? Data(contentsOf: url),
               let record = try? decoder.decode(PassWrapperStatus.self, from: data) {
                return record
            }
            await sleepThroughCancellation(for: pollInterval)
        }
        if let data = try? Data(contentsOf: url),
           let record = try? decoder.decode(PassWrapperStatus.self, from: data) {
            return record
        }
        return nil
    }

    private static func isAlive(pid: pid_t, started: PassWrapperStarted) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        guard let current = ProcessTree.identity(of: pid) else { return false }
        return current.startSeconds == started.startSeconds && current.startMicroseconds == started.startMicroseconds
    }
}
