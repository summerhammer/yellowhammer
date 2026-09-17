import Domain
import Foundation
import Journal
import Repositories

/// Everything an Act's work is handed: the one Project's Journal and this run's identity. There is
/// nothing else to hand it — a resumed Act rebuilds Attempt and Round counts, routes tried and
/// Worktree paths from the Journal, and an invocation holds nothing in memory between Acts.
public struct ActContext: Sendable {
    public let act: Act
    public let mode: NightMode
    public let trigger: ActTrigger
    public let runID: RunID
    public let journal: JournalStore
    /// The Night this Act belongs to. Once a Board is given, this carries the Night Card's issue id,
    /// re-read after `open` recorded it.
    public let night: NightRecord
    /// The single write path to the board, when this invocation was given one.
    public let outbox: Outbox?
    /// This Act's Night Card, when this invocation was given a Board.
    public let nightCard: NightCardMaintenance?
    /// Resolved mainlines for this Project's repositories.
    public let mainlines: ResolvedMainlines
    /// The Workspace Port, when this invocation was given one. The Engine never imports an adapter
    /// (MB1); `EngineCommand` is the one place this is wired.
    public let workspace: (any Workspace)?

    public init(
        act: Act,
        mode: NightMode,
        trigger: ActTrigger,
        runID: RunID,
        journal: JournalStore,
        night: NightRecord,
        outbox: Outbox? = nil,
        nightCard: NightCardMaintenance? = nil,
        mainlines: ResolvedMainlines = ResolvedMainlines(),
        workspace: (any Workspace)? = nil
    ) {
        self.act = act
        self.mode = mode
        self.trigger = trigger
        self.runID = runID
        self.journal = journal
        self.night = night
        self.outbox = outbox
        self.nightCard = nightCard
        self.mainlines = mainlines
        self.workspace = workspace
    }
}

/// One Act's work for one Project, then exit.
///
/// An invocation is handed exactly one Project's Journal and holds no other: the Engine never opens
/// a Journal (module boundary rule MB5), so nothing in it can name a sibling Project's. Two Acts of
/// the same Project must not run at once, so the invocation claims the Project's Act-scoped lease
/// before doing anything and stands down, out loud, when another run holds it. `run()` returns only
/// after the heartbeat task has ended (the task group is structured), so nothing — no timer, no task,
/// no cache — outlives the invocation; the process exits after `run()` returns.
public struct EngineInvocation: Sendable {
    public typealias ActWork = @Sendable (ActContext) async throws -> Void

    public let act: Act
    public let mode: NightMode
    public let trigger: ActTrigger
    public let runID: RunID
    /// The Night this Act belongs to: the date of its `night_start`, decided by `EngineCommand` from
    /// the Project's `[schedule]`. The Engine never reads configuration.
    public let nightStart: NightStart
    /// True for the land firing at `night_end`, which completes the Night whether or not the Cycle
    /// landed. Decided by `EngineCommand` from the clock against the Project's `[schedule]`.
    public let closesNight: Bool
    public let leasePolicy: LeasePolicy
    /// The Board Port, when this invocation maintains a Night Card. The Engine never opens a Journal
    /// or imports an adapter (MB1/MB5); `EngineCommand` is the one place this is wired.
    public let board: ActBoard?
    /// The Project's configured repositories, when provided.
    public let repositories: ProjectRepositories?
    public let mainlineRefresher: MainlineRefresher
    /// The Workspace Port, when this invocation maintains Worktrees. The Engine never imports an
    /// adapter (MB1/MB5); `EngineCommand` is the one place this is wired.
    public let workspace: (any Workspace)?
    private let journal: JournalStore
    private let work: ActWork

    public init(
        act: Act,
        mode: NightMode,
        nightStart: NightStart,
        journal: JournalStore,
        trigger: ActTrigger = .scheduled,
        runID: RunID = RunID(),
        closesNight: Bool = false,
        leasePolicy: LeasePolicy = .ruled,
        board: ActBoard? = nil,
        repositories: ProjectRepositories? = nil,
        mainlineRefresher: MainlineRefresher = MainlineRefresher(),
        workspace: (any Workspace)? = nil
    ) {
        self.act = act
        self.mode = mode
        self.trigger = trigger
        self.nightStart = nightStart
        self.journal = journal
        self.runID = runID
        self.closesNight = closesNight
        self.leasePolicy = leasePolicy
        self.board = board
        self.repositories = repositories
        self.mainlineRefresher = mainlineRefresher
        self.workspace = workspace
        self.work = { _ in throw EngineInvocationError.notImplemented(act) }
    }

    /// The Act's work under the lease is injectable so a test can drive an Act that completes;
    /// the real Acts arrive in later phases, and until then the public initializer's work throws
    /// `notImplemented`.
    internal init(
        act: Act,
        mode: NightMode,
        nightStart: NightStart,
        journal: JournalStore,
        trigger: ActTrigger = .scheduled,
        runID: RunID = RunID(),
        closesNight: Bool = false,
        leasePolicy: LeasePolicy = .ruled,
        board: ActBoard? = nil,
        repositories: ProjectRepositories? = nil,
        mainlineRefresher: MainlineRefresher = MainlineRefresher(),
        workspace: (any Workspace)? = nil,
        work: @escaping ActWork
    ) {
        self.act = act
        self.mode = mode
        self.trigger = trigger
        self.nightStart = nightStart
        self.journal = journal
        self.runID = runID
        self.closesNight = closesNight
        self.leasePolicy = leasePolicy
        self.board = board
        self.repositories = repositories
        self.mainlineRefresher = mainlineRefresher
        self.workspace = workspace
        self.work = work
    }

    /// The Project this invocation is scoped to: the one whose Journal it was given.
    public var projectID: ProjectID { journal.projectID }

    public func run() async throws {
        // A Feature name is only meaningful for the author Act.
        if case .forcedForFeature = trigger, act != .author {
            throw EngineInvocationError.featureNamedForNonAuthoringAct(act)
        }
        // Every step of the Act's life is appended to the Project's event log, so the Night Summary
        // can be computed from it. The records are written under the lease, before it is released,
        // and best-effort: failing to write one must not fail the Act, or stop it standing down.
        switch try journal.claimActLease(act: act, runID: runID, mode: mode, policy: leasePolicy) {
        case .held(let holder):
            _ = try? journal.append(.actStoodDown(holder: holder), act: act, runID: runID)
            throw EngineInvocationError.actLeaseHeld(act: act, projectID: projectID, by: holder)
        case .claimed:
            break
        }
        do {
            try await runUnderLease()
        } catch {
            // An Act that cannot complete exits with the lease released where it can. The Act's
            // failure is the error worth reporting: if the release fails too, the lease frees by its
            // TTL, exactly as it would after a crash.
            _ = try? journal.releaseActLease(runID: runID)
            throw error
        }
        try journal.releaseActLease(runID: runID)
    }

    /// The Act's life between claiming and releasing the Project. Any error thrown here is recorded
    /// as `ActIncomplete` on the way out, stamped with the Night where one was opened.
    private func runUnderLease() async throws {
        // The Night is recorded before anything else — before the trigger is even evaluated — so a
        // Night with nothing to do, or one whose first Act dies on the next line, still says it opened.
        let night: NightRecord
        do {
            night = try journal.openNight(nightStart: nightStart, mode: mode, act: act, runID: runID).night
        } catch {
            _ = try? journal.append(.actIncomplete(reason: String(describing: error)), act: act, runID: runID)
            throw error
        }
        _ = try? journal.append(.actStarted, act: act, runID: runID, nightID: night.id)
        do {
            // The Night Card is created before the trigger is even evaluated (DR7): an idle Night
            // still opens one. An `open` failure propagates and is recorded as `ActIncomplete` by the
            // catch below, and no work runs.
            var night = night
            var outbox: Outbox?
            var nightCard: NightCardMaintenance?
            if let board {
                let boxed = Outbox(journal: journal, board: board.writing, runID: runID, act: act, nightID: night.id)
                let maintenance = NightCardMaintenance(
                    journal: journal, outbox: boxed, provisioning: board.provisioning
                )
                _ = try await maintenance.open(night: night)
                night = try journal.night(id: night.id) ?? night
                outbox = boxed
                nightCard = maintenance
            }

            // Mainline refresh at Act start (after opening the Night/Night Card).
            var resolvedMainlines = ResolvedMainlines()
            if let repositories {
                let refreshResult = await mainlineRefresher.refresh(repositories: repositories)
                resolvedMainlines = refreshResult.mainlines
                for failure in refreshResult.failures {
                    _ = try? journal.append(
                        .mainlineFetchFailed(repository: failure.repository, reason: failure.reason),
                        act: act,
                        runID: runID,
                        nightID: night.id
                    )
                }
            }

            // Evaluate the trigger predicate under the lease.
            switch try ActTriggerPredicate.evaluate(act: act, trigger: trigger, journal: journal) {
            case .notMet(let reason):
                _ = try? journal.append(.actIdle(reason: reason), act: act, runID: runID, nightID: night.id)
            case .met:
                let context = ActContext(
                    act: act, mode: mode, trigger: trigger, runID: runID, journal: journal, night: night,
                    outbox: outbox, nightCard: nightCard, mainlines: resolvedMainlines, workspace: workspace
                )
                try await withLeaseHeartbeat(
                    every: leasePolicy.heartbeatDuration,
                    beat: { try journal.heartbeatActLease(runID: runID, policy: leasePolicy) },
                    body: { try await work(context) }
                )
            }
            // The land firing at `night_end` completes the Night whether or not the Cycle landed, and
            // whether or not its trigger was met. `night` is still current: this run has held the
            // Project's lease since it was opened, and only the engine writes the Journal.
            if closesNight, night.isOpen {
                try journal.closeNight(id: night.id, reason: .nightEnd, act: act, runID: runID)
                // The completion block needs `completedAt` and the verdict, which exist only once the
                // Night is closed, so completion is accepted and delivered after `closeNight`, from the
                // re-read record. A crash between `closeNight` and here leaves the card uncompleted:
                // the next Night's first Act sees a closed Night, not this one — a later phase may
                // repair it (spec: opened-and-died narrows to "opened and died", not every gap).
                if let nightCard, let closed = try journal.night(id: night.id) {
                    _ = try await nightCard.acceptCompletion(night: closed)
                    _ = try await nightCard.deliverCompletion(night: closed)
                }
            }
            _ = try? journal.append(.actEnded, act: act, runID: runID, nightID: night.id)
        } catch {
            _ = try? journal.append(
                .actIncomplete(reason: String(describing: error)), act: act, runID: runID, nightID: night.id
            )
            throw error
        }
    }
}

public enum EngineInvocationError: Error, Sendable, Equatable {
    case notImplemented(Act)
    /// Another run of the same Project holds its Act-scoped lease. This Act stood down and ran nothing.
    case actLeaseHeld(act: Act, projectID: ProjectID, by: ActLease)
    /// A Feature name was provided for a non-authoring Act. No lease is taken.
    case featureNamedForNonAuthoringAct(Act)
}

extension EngineInvocationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notImplemented(let act):
            return "Act '\(act.rawValue)' is not implemented"
        case .actLeaseHeld(let act, let projectID, let holder):
            return """
                The \(act.rawValue) Act for Project '\(projectID)' stood down: run \(holder.runID) has held the \
                Project for the \(holder.act.rawValue) Act since \(Self.timestamp(holder.claimedAt)) \
                (last heartbeat \(Self.timestamp(holder.heartbeatAt)); the lease expires at \
                \(Self.timestamp(holder.expiresAt)) unless heartbeated). No Act was run.
                """
        case .featureNamedForNonAuthoringAct(let act):
            return "A Feature name can only be provided for the author Act, not \(act.rawValue). No Act was run."
        }
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
