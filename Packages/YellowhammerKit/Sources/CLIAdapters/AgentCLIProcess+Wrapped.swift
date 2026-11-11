import Darwin
import Domain
import Foundation

private struct WrappedMonitorHooks {
    let promptWatch: (any PromptWatching)?
    let dispatchedAt: ProcessStartTime?
    let onSpawn: (@Sendable () -> Void)?
}

/// Monitoring for a pass launched by the terminal-owned wrapper. Yellowhammer has no parent/child
/// relationship to either process, so this path reads kernel identities and the wrapper's atomic
/// ending file; it never waits for or reaps either PID.
extension AgentCLIProcess {
    /// Monitors a CLI launched by `PassWrapper`. The wrapper identity record is the source of the
    /// CLI PID and start time; callers do not supply a PID because that would make stale PID reuse
    /// indistinguishable from the process this pass launched.
    ///
    /// `onSpawn` runs once a structurally valid wrapper identity record has been published. If
    /// startup never publishes one, the bounded wait ends as `wrapperLost` and `onSpawn` is not called.
    public func executeWrapped(
        identityFile: URL, endingFile: URL, timeout: Duration,
        dispatchedAt: ProcessStartTime? = nil,
        onSpawn: (@Sendable () -> Void)? = nil
    ) async -> AgentCLIExecution {
        let promptWatch = await promptSource.start()
        let result = await monitorWrapped(
            identityFile: identityFile, endingFile: endingFile, timeout: timeout,
            hooks: WrappedMonitorHooks(promptWatch: promptWatch, dispatchedAt: dispatchedAt, onSpawn: onSpawn)
        )
        await promptWatch?.stop()
        return result
    }

    // This is one lifecycle state machine: flattening it would obscure which identities have been
    // validated and which terminal states require a process sweep.
    // swiftlint:disable function_body_length cyclomatic_complexity
    private func monitorWrapped(
        identityFile: URL, endingFile: URL, timeout: Duration, hooks: WrappedMonitorHooks
    ) async -> AgentCLIExecution {

        let clock = ContinuousClock()
        let started = clock.now
        let startupDeadline = started.advanced(by: min(timeout, .seconds(5)))
        var identity: PassWrapperIdentity?
        while clock.now < startupDeadline {
            let candidate = PassWrapperIdentity.read(from: identityFile)
            if let candidate, Self.validWrappedShape(candidate) {
                identity = candidate
                hooks.onSpawn?()
                break
            }
            await Self.sleepThroughCancellation(for: pollInterval)
        }

        if identity == nil {
            Self.publishStartupCancellation(for: identityFile)
            // Close the race where the child publishes its identity between our last read and the
            // cancellation marker becoming visible. The wrapper checks this marker before exec.
            if let candidate = PassWrapperIdentity.read(from: identityFile), Self.validWrappedShape(candidate) {
                identity = candidate
                hooks.onSpawn?()
            }
        }
        guard let identity else {
            return Self.wrappedExecution(
                pid: 0, end: .wrapperLost, leftovers: [], dispatchedAt: hooks.dispatchedAt ?? Self.now(), tracked: []
            )
        }
        // The caller can supply the true dispatch time, before a tab shell is created. Otherwise,
        // use the wrapper's kernel start as the best boundary available to this detached monitor.
        let runDispatchedAt = hooks.dispatchedAt ?? ProcessStartTime(
            seconds: identity.wrapperStartSeconds, microseconds: identity.wrapperStartMicroseconds
        )
        let cliIdentity = Self.cliTracked(identity) ?? Self.recordedCLI(identity)
        var tracked: Set<ProcessTree.TrackedProcess> = [cliIdentity]
        var lastSnapshot: ContinuousClock.Instant?
        var cliGoneAt: ContinuousClock.Instant?
        let deadline = started.advanced(by: timeout)

        while true {
            if !Self.isCurrent(cliIdentity) {
                if cliGoneAt == nil { cliGoneAt = clock.now }
                if let ending = PassWrapperEnding.read(from: endingFile) {
                    return await finishWrappedCLI(
                        identity: identity, ending: Self.runEnd(ending), dispatchedAt: runDispatchedAt, tracked: tracked
                    )
                }
                if clock.now - cliGoneAt! >= .milliseconds(750) {
                    return await finishWrappedCLI(
                        identity: identity, ending: .wrapperLost, dispatchedAt: runDispatchedAt, tracked: tracked
                    )
                }
                await Self.sleepThroughCancellation(for: pollInterval)
                continue
            }

            guard Self.wrapperTracked(identity) != nil else {
                // A clean finish can land between the two liveness checks: the CLI exits, the wrapper
                // writes its ending and exits. Re-check before calling the wrapper lost.
                if !Self.isCurrent(cliIdentity) { continue }
                // The wrapper vanished while its CLI is live. Contain the CLI and its tracked tree.
                let end = await containWrappedCLI(cliIdentity, tracked: &tracked, reason: .wrapperLost)
                return Self.wrappedExecution(
                    pid: identity.cliPID, end: end, leftovers: [], dispatchedAt: runDispatchedAt, tracked: tracked
                )
            }

            if lastSnapshot == nil || clock.now - lastSnapshot! >= snapshotInterval {
                tracked.formUnion(ProcessTree.descendants(of: identity.cliPID))
                lastSnapshot = clock.now
            }

            if let promptWatch = hooks.promptWatch,
               let prompt = await Self.attributedPrompt(
                   in: promptWatch, leaderPID: identity.cliPID, tracked: &tracked, expectedLeader: cliIdentity
               ) {
                let reason = TerminationReason.permissionPrompt(prompt.detail)
                let end = await containWrappedCLI(cliIdentity, tracked: &tracked, reason: reason)
                return Self.wrappedExecution(
                    pid: identity.cliPID, end: end, leftovers: [], dispatchedAt: runDispatchedAt, tracked: tracked
                )
            }
            if Task.isCancelled {
                let end = await containWrappedCLI(cliIdentity, tracked: &tracked, reason: .aborted)
                return Self.wrappedExecution(
                    pid: identity.cliPID, end: end, leftovers: [], dispatchedAt: runDispatchedAt, tracked: tracked
                )
            }
            if clock.now >= deadline {
                let end = await containWrappedCLI(cliIdentity, tracked: &tracked, reason: .timedOut(after: timeout))
                return Self.wrappedExecution(
                    pid: identity.cliPID, end: end, leftovers: [], dispatchedAt: runDispatchedAt, tracked: tracked
                )
            }
            try? await Task.sleep(for: pollInterval)
        }
    }
    // swiftlint:enable function_body_length cyclomatic_complexity

    private func finishWrappedCLI(
        identity: PassWrapperIdentity, ending: RunEnd, dispatchedAt: ProcessStartTime,
        tracked: Set<ProcessTree.TrackedProcess>
    ) async -> AgentCLIExecution {
        let leftovers = await sweepAfterExit(tracked: tracked)
        return Self.wrappedExecution(
            pid: identity.cliPID, end: ending, leftovers: leftovers, dispatchedAt: dispatchedAt, tracked: tracked
        )
    }

    private static func now() -> ProcessStartTime {
        var timestamp = timeval()
        gettimeofday(&timestamp, nil)
        return ProcessStartTime(seconds: UInt64(timestamp.tv_sec), microseconds: UInt64(timestamp.tv_usec))
    }

    private static func validWrappedShape(_ identity: PassWrapperIdentity) -> Bool {
        identity.wrapperPID > 1 && identity.cliPID > 1 && identity.processGroup == identity.cliPID
            && identity.session == identity.cliPID
    }

    private static func wrapperTracked(_ identity: PassWrapperIdentity) -> ProcessTree.TrackedProcess? {
        guard let current = ProcessTree.identity(of: identity.wrapperPID),
              current.startSeconds == identity.wrapperStartSeconds,
              current.startMicroseconds == identity.wrapperStartMicroseconds else { return nil }
        return current
    }

    private static func recordedCLI(_ identity: PassWrapperIdentity) -> ProcessTree.TrackedProcess {
        ProcessTree.TrackedProcess(
            pid: identity.cliPID, processGroup: identity.processGroup, session: identity.session,
            commandName: "agent CLI", startSeconds: identity.cliStartSeconds,
            startMicroseconds: identity.cliStartMicroseconds
        )
    }

    private static func publishStartupCancellation(for identityFile: URL) {
        _ = FileManager.default.createFile(
            atPath: identityFile.path + ".cancel", contents: Data(), attributes: [.posixPermissions: 0o600]
        )
    }

    private static func cliTracked(_ identity: PassWrapperIdentity) -> ProcessTree.TrackedProcess? {
        guard Self.validWrappedShape(identity), let current = ProcessTree.identity(of: identity.cliPID),
              current.startSeconds == identity.cliStartSeconds,
              current.startMicroseconds == identity.cliStartMicroseconds else { return nil }
        return current
    }

    private static func isCurrent(_ process: ProcessTree.TrackedProcess) -> Bool {
        guard let current = ProcessTree.identity(of: process.pid) else { return false }
        return current.startSeconds == process.startSeconds && current.startMicroseconds == process.startMicroseconds
    }

    private static func runEnd(_ ending: PassWrapperEnding) -> RunEnd {
        ending.exited ? .exited(status: ending.value) : .signaled(ending.value)
    }

    private static func wrappedExecution(
        pid: pid_t, end: RunEnd, leftovers: [LeftoverProcess], dispatchedAt: ProcessStartTime,
        tracked: Set<ProcessTree.TrackedProcess>
    ) -> AgentCLIExecution {
        AgentCLIExecution(
            pid: pid, processGroup: pid > 0 ? pid : 0, end: end, leftovers: leftovers,
            snapshot: makeSnapshot(leaderPID: pid, dispatchedAt: dispatchedAt, tracked: tracked)
        )
    }

    /// Wrapper-owned leaders cannot be waited for/reaped. Groups are signalled only while a live,
    /// identity-matched tracked process is confirmed in them; descendants are also signalled by PID
    /// plus kernel start time.
    private func containWrappedCLI(
        _ cli: ProcessTree.TrackedProcess, tracked: inout Set<ProcessTree.TrackedProcess>, reason: TerminationReason
    ) async -> RunEnd {
        if Self.isCurrent(cli) { tracked.formUnion(ProcessTree.descendants(of: cli.pid)) }
        Self.signal(tracked, SIGTERM)
        Self.signalGroups(of: tracked, SIGTERM)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: gracePeriod)
        while clock.now < deadline {
            Self.sweepForNewDescendants(leaderPID: cli.pid, leaderReaped: !Self.isCurrent(cli), tracked: &tracked)
            if Self.externalTreeGone(cli: cli, tracked: tracked) { return Self.wrappedEnd(reason, forcedKill: false) }
            await Self.sleepThroughCancellation(for: pollInterval)
        }

        Self.sweepForNewDescendants(leaderPID: cli.pid, leaderReaped: !Self.isCurrent(cli), tracked: &tracked)
        let survivors = tracked.filter { !ProcessTree.isGone($0) }
        Self.signal(survivors, SIGKILL)
        Self.signalGroups(of: survivors, SIGKILL)
        let killDeadline = clock.now.advanced(by: .seconds(1))
        while clock.now < killDeadline, !Self.externalTreeGone(cli: cli, tracked: tracked) {
            Self.sweepForNewDescendants(leaderPID: cli.pid, leaderReaped: !Self.isCurrent(cli), tracked: &tracked)
            let remaining = tracked.filter { !ProcessTree.isGone($0) }
            Self.signal(remaining, SIGKILL)
            Self.signalGroups(of: remaining, SIGKILL)
            await Self.sleepThroughCancellation(for: pollInterval)
        }
        return Self.wrappedEnd(reason, forcedKill: true)
    }

    private static func externalTreeGone(
        cli: ProcessTree.TrackedProcess, tracked: Set<ProcessTree.TrackedProcess>
    ) -> Bool {
        !isCurrent(cli) && tracked.allSatisfy(ProcessTree.isGone)
    }

    private static func wrappedEnd(_ reason: TerminationReason, forcedKill: Bool) -> RunEnd {
        switch reason {
        case .timedOut(let after): .timedOut(after: after, forcedKill: forcedKill)
        case .aborted: .aborted(forcedKill: forcedKill)
        case .permissionPrompt(let detail): .promptBlocked(detail: detail, forcedKill: forcedKill)
        case .wrapperLost: .wrapperLost
        }
    }
}
