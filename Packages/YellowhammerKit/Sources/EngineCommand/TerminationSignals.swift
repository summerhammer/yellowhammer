import Darwin
import Dispatch
import Foundation
import Synchronization

/// Turns the first `SIGTERM`/`SIGINT` `yh` receives while running an Act into `Task` cancellation of
/// the Act's own work, instead of letting the default disposition kill the process outright (issue
/// #151). The abort path this unblocks already exists: `AgentCLIProcess.wait` checks
/// `Task.isCancelled` and sends `SIGTERM` to the agent CLI's process group, waits the 3 s grace, then
/// escalates to `SIGKILL` and sweeps descendants; `CardRun` (#150) stops at the next Attempt boundary
/// on cancellation rather than spending the Attempt budget; `EngineInvocation.runUnderLease` then
/// appends `.actIncomplete` and releases the Act Lease.
///
/// Used only by the Act commands (`author`/`build`/`land`) — `setup`'s interactive prompts, `doctor`
/// and the other subcommands keep the default Ctrl-C behaviour.
enum TerminationSignals {
    /// The default grace: the abort path's own SIGTERM-to-SIGKILL escalation is a 3 s grace plus
    /// whatever Journal writes and Outbox posts `EngineInvocation`'s catch path performs on the way
    /// out. The generated LaunchAgent (`ScheduledJob.swift`) sets no `ExitTimeOut`, so `launchd`'s
    /// own default applies: it sends `SIGKILL` 20 s after its `SIGTERM` if the process has not exited.
    /// This deadline must comfortably clear the abort path's own escalation while leaving headroom
    /// under that 20 s hard stop.
    static let defaultDeadline: Duration = .seconds(10)

    /// One signal this run observed, and how many times it (or its twin) has been delivered.
    private enum State {
        case running
        /// The first signal cancelled the body; `count` is how many signals have landed in total.
        case signalled(Int32, count: Int)
    }

    /// Tracks whether a real signal has ever landed on this process. Once a real signal has landed,
    /// restoring `SIG_DFL` is permanently unsafe: `sigaction`'s `postsig` re-reads the disposition
    /// table at the moment it delivers a signal to a thread, not at `kill()` time, so a restore that
    /// lands in the window between the kqueue event firing and `postsig` running on the signal's chosen
    /// thread would still hand that same signal to the default action — killing the process out from
    /// under the graceful path that was already handling it. Once a signal is truly observed on the
    /// process, restoring `SIG_DFL` is permanently avoided so subsequent runs (e.g. later tests in the
    /// same test host process) cannot trip the default termination action.
    private static let processObservedRealSignal = Mutex(false)

    /// Admits one `run` at a time, process-wide (issue #215). Dispositions and signal sources are
    /// global to the process, so two overlapping runs corrupt each other: one run's `defer` restores
    /// `SIG_DFL` while the other has a real signal in flight (killing the process), and a real signal
    /// fires every live `DispatchSource`, cancelling a run it was never sent to. Production runs one
    /// Act per process, so the gate never makes anything wait there; only a test host, where
    /// `ActCommand.run` and the signal tests run concurrently, ever queues on it.
    private static let gate = Gate()

    /// Runs `body` in an unstructured `Task`, with `SIGTERM`/`SIGINT` handlers installed only for the
    /// duration. On the first signal, cancels the body's `Task` and starts `deadline`; if the body has
    /// not finished by then, `exit` is invoked with `128 + signal number` and this function does not
    /// return. On a second signal (either `SIGTERM` or `SIGINT`), `exit` is invoked immediately, the
    /// same way. Two signals coalesced into one kqueue event (`source.data > 1`, e.g. two `SIGTERM`s
    /// delivered before GCD's queue drains) are replayed through `deliver` that many times, so a
    /// coalesced pair is a first-then-second, exactly as two separate deliveries would be.
    ///
    /// When the body finishes on its own, the signal sources are cancelled. Both dispositions are
    /// restored to `SIG_DFL` unless a real signal actually landed on this process — see the `defer` block
    /// below for why an unconditional restore is unsafe.
    ///
    /// `exit` never actually returns in production (`_exit`), but is typed to return `Void` — not
    /// `Never` — so a test can inject a closure that records the call and returns, without also having
    /// to satisfy `Never`'s inhabitation from a closure that must not really terminate the test
    /// process. Such a closure must not itself block forever: doing so leaks a libdispatch worker
    /// thread and can starve *other* tests' signal delivery (found empirically).
    ///
    /// `signalHook`, when supplied, is handed the exact closure the real `DispatchSource` handlers
    /// call — a test seam so a test can drive the first-signal/second-signal/deadline paths by
    /// calling it directly, without delivering a real signal to the test process. Production never
    /// passes one.
    static func run(
        deadline: Duration = defaultDeadline,
        exit: @Sendable @escaping (Int32) -> Void = { _exit($0) },
        signalHook: (@escaping @Sendable (Int32) -> Void) -> Void = { _ in },
        body: @Sendable @escaping () async throws -> Void
    ) async throws {
        await Self.gate.enter()
        let coordinator = Coordinator(deadline: deadline, exit: exit)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: coordinator.signalQueue)
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: coordinator.signalQueue)

        // Install the no-op handler *before* creating and resuming the DispatchSources: a
        // `DispatchSource` for a signal observes delivery through the kernel's normal signal
        // mechanism, it does not itself suppress the default disposition. A signal that lands while
        // the disposition is still `SIG_DFL` would run the default action — terminate the process —
        // before the source ever gets a chance to fire. Handler first closes that window; a signal
        // that lands in the (much narrower) gap before the source is armed is merely swallowed by the
        // no-op handler, not fatal.
        Self.installNoOpHandler(SIGTERM)
        Self.installNoOpHandler(SIGINT)
        termSource.setEventHandler { [termSource] in
            Self.processObservedRealSignal.withLock { $0 = true }
            for _ in 0..<max(1, termSource.data) { coordinator.deliver(SIGTERM) }
        }
        intSource.setEventHandler { [intSource] in
            Self.processObservedRealSignal.withLock { $0 = true }
            for _ in 0..<max(1, intSource.data) { coordinator.deliver(SIGINT) }
        }
        termSource.resume()
        intSource.resume()

        // Only now — handler installed, sources armed — is it safe to let the body actually start: a
        // test proves the wiring by signalling itself from inside the body, and that must not be able
        // to race ahead of the installation above.
        let task = Task { try await body() }
        coordinator.attach(task)
        signalHook(coordinator.deliver)

        defer {
            termSource.cancel()
            intSource.cancel()
            coordinator.cancelDeadline()
            // Restored to `SIG_DFL` unless a real signal actually landed on this process: `sigaction`'s
            // `postsig` re-reads the disposition table at the moment it delivers a signal to a
            // thread, not at `kill()` time, so a restore that lands in the (sub-millisecond) window
            // between the kqueue event firing and `postsig` running on the signal's chosen thread
            // would still hand that same signal to the default action — killing the process out from
            // under the graceful path that was already handling it (found empirically: this raced
            // the test host to death about 1 run in 4). Once a signal is truly observed on the process
            // there is nothing left to protect by restoring `SIG_DFL` before the process exits anyway.
            if !Self.processObservedRealSignal.withLock({ $0 }) {
                Self.restoreDefault(SIGTERM)
                Self.restoreDefault(SIGINT)
            }
            Self.gate.leave()
        }

        do {
            try await withTaskCancellationHandler(
                operation: { try await task.value },
                onCancel: { task.cancel() }
            )
        } catch {
            if let signalNumber = coordinator.signalNumber {
                throw InterruptedError(signal: signalNumber, underlying: error)
            }
            throw error
        }
    }

    /// A no-op *caught* handler, never `SIG_IGN`: an ignored disposition survives `exec`, so every
    /// child `yh` spawns while this runs — the agent CLI, `git`, the headless app for
    /// `--post-notification` — would inherit SIGTERM-ignored, and the engine's own graceful SIGTERM to
    /// the CLI's process group (the abort path above) would silently stop working. A caught
    /// disposition resets to `SIG_DFL` on `exec`, so a spawned child is unaffected either way.
    /// `DispatchSource.makeSignalSource` fires from its own kqueue registration even with a no-op
    /// handler installed — it does not depend on the handler actually doing anything.
    private static func installNoOpHandler(_ signalNumber: Int32) {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in }
        action.sa_flags = SA_RESTART
        sigemptyset(&action.sa_mask)
        sigaction(signalNumber, &action, nil)
    }

    private static func restoreDefault(_ signalNumber: Int32) {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&action.sa_mask)
        sigaction(signalNumber, &action, nil)
    }

    /// A FIFO admission gate: `enter` suspends (never blocks a thread) while another `run` holds it,
    /// and `leave` hands it straight to the longest waiter. A waiter is not cancellable — nothing ever
    /// waits in production (see ``gate``).
    private final class Gate: Sendable {
        /// Whether a `run` holds the gate, and the runs queued behind it, oldest first.
        private let state = Mutex<(busy: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

        func enter() async {
            await withCheckedContinuation { continuation in
                let admitted = state.withLock { state -> Bool in
                    guard state.busy else {
                        state.busy = true
                        return true
                    }
                    state.waiters.append(continuation)
                    return false
                }
                if admitted { continuation.resume() }
            }
        }

        func leave() {
            let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard !state.waiters.isEmpty else {
                    state.busy = false
                    return nil
                }
                return state.waiters.removeFirst()
            }
            next?.resume()
        }
    }

    /// The mutable state one `run` call owns: which signal (if any) landed first, the body's `Task`
    /// (assigned only once installation is complete — see `run`), and the deadline `Task` a first
    /// signal starts. A class, not a struct, so `run`'s closures (the event handlers, `signalHook`,
    /// the deadline body) all share one identity without each needing its own `Mutex` box.
    private final class Coordinator: Sendable {
        let signalQueue = DispatchQueue(label: "dev.yellowhammer.termination-signals")

        private let deadline: Duration
        private let exit: @Sendable (Int32) -> Void
        private let state = Mutex(State.running)
        private let taskBox = Mutex<Task<Void, any Error>?>(nil)
        private let deadlineBox = Mutex<Task<Void, Never>?>(nil)

        init(deadline: Duration, exit: @escaping @Sendable (Int32) -> Void) {
            self.deadline = deadline
            self.exit = exit
        }

        var signalNumber: Int32? {
            if case .signalled(let signalNumber, _) = state.withLock({ $0 }) { signalNumber } else { nil }
        }

        private var alreadyDelivered: Bool {
            state.withLock { if case .signalled = $0 { true } else { false } }
        }

        /// Stores the body's `Task`, then — since a signal (real or, in a test, seam-driven) could
        /// have landed in the narrow window between the sources being armed and this call — cancels
        /// it immediately if one already has. `deliver` always writes `state` before reading
        /// `taskBox`, so every interleaving of the two ends with the task cancelled at least once
        /// (cancellation is idempotent).
        func attach(_ task: Task<Void, any Error>) {
            taskBox.withLock { $0 = task }
            if alreadyDelivered { task.cancel() }
        }

        func cancelDeadline() {
            deadlineBox.withLock { $0?.cancel() }
        }

        @Sendable func deliver(_ signalNumber: Int32) {
            let isFirst = state.withLock { current -> Bool in
                switch current {
                case .running:
                    current = .signalled(signalNumber, count: 1)
                    return true
                case .signalled(let first, let count):
                    current = .signalled(first, count: count + 1)
                    return false
                }
            }
            if isFirst {
                taskBox.withLock { $0?.cancel() }
                let deadline = deadline
                let exit = exit
                let deadlineTask = Task {
                    try? await Task.sleep(for: deadline)
                    guard !Task.isCancelled else { return }
                    exit(128 + signalNumber)
                }
                deadlineBox.withLock { $0 = deadlineTask }
            } else {
                exit(128 + signalNumber)
            }
        }
    }

    /// Surfaces a body ended by a signal as a clear, Operator-facing error rather than a bare
    /// `CancellationError`. Uses the mandated interruption wording (CLAUDE.md): the Card is
    /// reclaimable, and no partial state was written as if it were complete — never that the Card
    /// "continues".
    struct InterruptedError: Error, CustomStringConvertible {
        let signal: Int32
        let underlying: any Error

        private var signalName: String {
            switch signal {
            case SIGTERM: "SIGTERM"
            case SIGINT: "SIGINT"
            default: "signal \(signal)"
            }
        }

        var description: String {
            "interrupted by \(signalName): the Act was stopped; the Card is reclaimable, and no partial " +
                "state was written as if it were complete."
        }
    }
}
