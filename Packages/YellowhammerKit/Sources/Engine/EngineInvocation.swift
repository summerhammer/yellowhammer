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
    /// The Board Port, when this invocation was given one. The Engine never imports an adapter (MB1);
    /// `EngineCommand` is the one place this is wired.
    public let board: ActBoard?
    /// Resolved mainlines for this Project's repositories.
    public let mainlines: ResolvedMainlines
    /// The Workspace Port, when this invocation was given one. The Engine never imports an adapter
    /// (MB1); `EngineCommand` is the one place this is wired.
    public let workspace: (any Workspace)?
    /// The Project's configured repositories, when provided — the Readiness Check's provenance and
    /// citation resolution need these to test a Transcription Block or resolve a Spec Citation.
    public let repositories: ProjectRepositories?
    /// The Operator's board identity, machine-configured (roadmap P11.1; carried on the context itself,
    /// not threaded through each consumer's initializer, since every consumer already has this).
    public let operatorIdentity: OperatorIdentity

    public init(
        act: Act,
        mode: NightMode,
        trigger: ActTrigger,
        runID: RunID,
        journal: JournalStore,
        night: NightRecord,
        outbox: Outbox? = nil,
        nightCard: NightCardMaintenance? = nil,
        board: ActBoard? = nil,
        mainlines: ResolvedMainlines = ResolvedMainlines(),
        workspace: (any Workspace)? = nil,
        repositories: ProjectRepositories? = nil,
        operatorIdentity: OperatorIdentity = .none
    ) {
        self.act = act
        self.mode = mode
        self.trigger = trigger
        self.runID = runID
        self.journal = journal
        self.night = night
        self.outbox = outbox
        self.nightCard = nightCard
        self.board = board
        self.mainlines = mainlines
        self.workspace = workspace
        self.repositories = repositories
        self.operatorIdentity = operatorIdentity
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
    /// The Night Summary's Bounds (roadmap P11.6): plain Ints, read from `project.bounds` only by
    /// `EngineCommand` — the Engine never imports `Config`.
    public let nightCardBounds: NightCardMaintenance.Bounds
    /// Pure readiness judgement used only for the first Act's opening measurement.
    public let openingReadiness: ReadinessCheck?
    /// The Operator's board identity, machine-configured (roadmap P11.1): built once by `EngineCommand`
    /// and carried onto every `ActContext` this invocation hands its work.
    public let operatorIdentity: OperatorIdentity
    /// Posts local Exception Notifications for `halted` and `closed` (roadmap P12.5). `.silent` by
    /// default, so no invocation spawns a process unless `EngineCommand` wires the real launcher in.
    public let notifier: ExceptionNotifier
    /// Rehearsal-only (P15.3): when given, this run's `Outbox` kills its own process at the n-th
    /// applied entry the switch names — never wired outside a rehearsal Night's `--rehearsal`.
    public let outboxKill: RehearsalOutboxKill?
    /// The one scrub every narrative this invocation's Outbox posts passes (OQ146/OQ147, R23), built by
    /// `EngineCommand` from the credentials it holds. `.none` by default.
    public let narrativeScrub: @Sendable () -> NarrativeScrub
    /// Not `private`: the module-internal notification extension reads it (roadmap P12.5).
    let journal: JournalStore
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
        workspace: (any Workspace)? = nil,
        nightCardBounds: NightCardMaintenance.Bounds = NightCardMaintenance.Bounds(),
        openingReadiness: ReadinessCheck? = nil,
        operatorIdentity: OperatorIdentity = .none,
        notifier: ExceptionNotifier = .silent,
        outboxKill: RehearsalOutboxKill? = nil,
        narrativeScrub: @escaping @Sendable () -> NarrativeScrub = { .none }
    ) {
        self.narrativeScrub = narrativeScrub
        self.act = act
        self.mode = mode
        self.trigger = trigger
        self.nightStart = nightStart
        self.journal = journal
        self.runID = runID
        self.closesNight = closesNight
        self.leasePolicy = leasePolicy
        self.board = board
        self.nightCardBounds = nightCardBounds
        self.openingReadiness = openingReadiness
        self.repositories = repositories
        self.mainlineRefresher = mainlineRefresher
        self.workspace = workspace
        self.operatorIdentity = operatorIdentity
        self.notifier = notifier
        self.outboxKill = outboxKill
        self.work = { _ in throw EngineInvocationError.notImplemented(act) }
    }

    /// The Act's work under the lease is injectable: `EngineCommand` wires in the real work an Act's
    /// own phase has landed (the build Act's is `BuildAct.work`, P8.1), and a test drives an Act that
    /// completes the same way. An Act whose phase has not landed yet keeps the public initializer's
    /// work, which throws `notImplemented`.
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
        workspace: (any Workspace)? = nil,
        nightCardBounds: NightCardMaintenance.Bounds = NightCardMaintenance.Bounds(),
        openingReadiness: ReadinessCheck? = nil,
        operatorIdentity: OperatorIdentity = .none,
        notifier: ExceptionNotifier = .silent,
        outboxKill: RehearsalOutboxKill? = nil,
        narrativeScrub: @escaping @Sendable () -> NarrativeScrub = { .none },
        work: @escaping ActWork
    ) {
        self.narrativeScrub = narrativeScrub
        self.act = act
        self.mode = mode
        self.trigger = trigger
        self.nightStart = nightStart
        self.journal = journal
        self.runID = runID
        self.closesNight = closesNight
        self.leasePolicy = leasePolicy
        self.board = board
        self.nightCardBounds = nightCardBounds
        self.openingReadiness = openingReadiness
        self.repositories = repositories
        self.mainlineRefresher = mainlineRefresher
        self.workspace = workspace
        self.operatorIdentity = operatorIdentity
        self.notifier = notifier
        self.outboxKill = outboxKill
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
        let opening: NightOpening
        do {
            opening = try journal.openNight(nightStart: nightStart, mode: mode, act: act, runID: runID)
        } catch {
            _ = try? journal.append(.actIncomplete(reason: String(describing: error)), act: act, runID: runID)
            throw error
        }
        _ = try? journal.append(.actStarted, act: act, runID: runID, nightID: opening.night.id)
        // Declared before the `do`: the halted path in `catch` below needs the Night Card (P12.5).
        var night = opening.night
        var outbox: Outbox?
        var nightCard: NightCardMaintenance?
        do {
            // Before the Night Card: a refused identity or an unresolved board scope halts the Act
            // with no work done (roadmap P17.5; OQ85, OQ136).
            try await boardPreflight()
            // The Night Card is created before the trigger is even evaluated (DR7): an idle Night
            // still opens one. An `open` failure propagates and is recorded as `ActIncomplete` by the
            // catch below, and no work runs.
            (outbox, nightCard) = try await openNightCardIfNeeded(night: night)
            if outbox != nil {
                night = try journal.night(id: night.id) ?? night
            }

            let resolvedMainlines = await refreshMainlines(night: night)
            if opening.isFirstAct {
                await recordOpeningReadiness(night: night, mainlines: resolvedMainlines)
            }

            // Evaluate the trigger predicate under the lease.
            switch try ActTriggerPredicate.evaluate(act: act, trigger: trigger, journal: journal) {
            case .notMet(let reason):
                _ = try? journal.append(.actIdle(reason: reason), act: act, runID: runID, nightID: night.id)
            case .met:
                let context = ActContext(
                    act: act, mode: mode, trigger: trigger, runID: runID, journal: journal, night: night,
                    outbox: outbox, nightCard: nightCard, board: board, mainlines: resolvedMainlines,
                    workspace: workspace, repositories: repositories, operatorIdentity: operatorIdentity
                )
                try await withLeaseHeartbeat(
                    every: leasePolicy.heartbeatDuration,
                    beat: { try journal.heartbeatActLease(runID: runID, policy: leasePolicy) },
                    body: { try await work(context) }
                )
            }
            try await maintainRollUps(night: night, outbox: outbox)
            // Posts `closed` once the Night Card's completion is recorded; `opened` never posts (G-10).
            try await closeNightIfNeeded(night, card: nightCard, outbox: outbox)
            appendClosing(.actEnded, night: night)
        } catch {
            await recordHalt(error, night: night, nightCard: nightCard, outbox: outbox)
            throw error
        }
    }

    // `boardPreflight()` lives in EngineInvocation+BoardPreflight.swift — split out for the file/type
    // length limits.

    /// Ensures the Project's Night Card is live when a board is wired, replacing an archived card. Split out of
    /// `runUnderLease` to keep that function under the function body length limit; the caller re-reads
    /// the Night afterwards, since `open` may have recorded its Night Card issue id.
    private func openNightCardIfNeeded(night: NightRecord) async throws -> (Outbox?, NightCardMaintenance?) {
        guard let board else { return (nil, nil) }
        let boxed = Outbox(
            journal: journal, board: board.writing, reading: board.reading, runID: runID, act: act, nightID: night.id,
            installation: board.installation, scrub: narrativeScrub
        ) { [outboxKill] in outboxKill?.interrupt($0) }
        let maintenance = NightCardMaintenance(
            journal: journal, outbox: boxed, provisioning: board.provisioning, bounds: nightCardBounds
        )
        let opening = try await maintenance.open(night: night)
        if !night.isOpen, case .opened = opening {
            _ = try await maintenance.acceptCompletion(night: night)
            _ = try await maintenance.deliverCompletion(night: night)
        }
        return (boxed, maintenance)
    }

    /// Reads the Project board once before this Act's work, then applies the same readiness inputs
    /// without claiming a Card lease or mutating the Journal. Any failed read is recorded as unknown.
    private func recordOpeningReadiness(night: NightRecord, mainlines: ResolvedMainlines) async {
        guard let board else {
            try? journal.recordOpeningReadyState(nightID: night.id, state: .unknown)
            return
        }
        var cursor: BoardCursor?
        var requests = 0
        do {
            var objects: [BoardObject] = []
            repeat {
                guard requests < 40 else {
                    try journal.recordOpeningReadyState(nightID: night.id, state: .unknown)
                    return
                }
                let page = try await board.reading.objects(
                    updatedSince: nil, after: cursor, pageSize: 200
                )
                requests += 1
                objects += page.objects
                cursor = page.nextCursor
            } while cursor != nil
            let state = try await openingReadyState(objects: objects, mainlines: mainlines)
            try journal.recordOpeningReadyState(nightID: night.id, state: state)
        } catch {
            try? journal.recordOpeningReadyState(nightID: night.id, state: .unknown)
        }
    }

    private func openingReadyState(
        objects: [BoardObject], mainlines: ResolvedMainlines
    ) async throws -> OpeningReadyState {
        let cards = try journal.cards()
        let knownIDs = Set(cards.map(\.issueID))
        let unbackedCard = objects.contains(where: { object in
            !knownIDs.contains(object.id.rawValue) &&
                object.labels.contains(where: { $0.caseInsensitiveCompare("Card") == .orderedSame })
        })
        guard let openingReadiness else { return cards.isEmpty && !unbackedCard ? .zero : .unknown }
        let byID = Dictionary(uniqueKeysWithValues: objects.map { ($0.id.rawValue, $0) })
        var unknown = unbackedCard
        for card in cards where card.state == .todo {
            guard let object = byID[card.issueID] else { unknown = true; continue }
            switch try await openingReadiness.inspectAtOpening(
                card: card, object: object, journal: journal, repositories: repositories, mainlines: mainlines
            ) {
            case .ready: return .nonzero
            case .unknown: unknown = true
            case .notReady: break
            }
        }
        return unknown ? .unknown : .zero
    }
    private func refreshMainlines(night: NightRecord) async -> ResolvedMainlines {
        guard let repositories else { return ResolvedMainlines() }
        let result = await mainlineRefresher.refresh(repositories: repositories)
        for failure in result.failures {
            _ = try? journal.append(
                .mainlineFetchFailed(repository: failure.repository, reason: failure.reason),
                act: act, runID: runID, nightID: night.id
            )
        }
        return result.mainlines
    }

    // `closeNightIfNeeded(_:card:outbox:)` lives in EngineInvocation+ExceptionNotification.swift, next
    // to the `notifyClosed` it calls — split out to keep this type under the type body length limit.
}

public enum EngineInvocationError: Error, Sendable, Equatable {
    case notImplemented(Act)
    /// Another run of the same Project holds its Act-scoped lease. This Act stood down and ran nothing.
    case actLeaseHeld(act: Act, projectID: ProjectID, by: ActLease)
    /// A Feature name was provided for a non-authoring Act. No lease is taken.
    case featureNamedForNonAuthoringAct(Act)
}

// `EngineInvocationError`'s `CustomStringConvertible` conformance lives in
// EngineInvocationError+Description.swift, split out to keep this file under the file length limit.
