import ArgumentParser
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Testing

// Event recording: engine invocations record their Acts' lifecycle and state changes to the Journal.

private let nightStart = NightStart(rawValue: "2026-09-15")!

private func runAct(
    _ act: Act,
    project: String,
    in directory: borrowing ConfigurationDirectory,
    force: Bool = false
) async throws {
    var args = [act.rawValue, "--project", project]
    if force {
        args.append("--force")
    }
    let parsed = try RootCommand.parseAsRoot(args)
    let command = try #require(parsed as? any ActCommand)
    // No Board bound: this suite is about the event log, not the Night Card (NightCardTests).
    try await command.makeInvocation(configurationDirectory: directory.url, now: Date(), bindBoard: nil).run()
}

@Test("Running an Act through the engine records ActStarted, then ActIncomplete on notImplemented")
func actNotImplementedRecordsEvents() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))

    // Every Act's work has landed, so an Act with no work injected is built directly: it keeps the
    // public initializer's work, which throws `notImplemented`.
    let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)
    let invocation = EngineInvocation(act: .author, mode: .real, nightStart: nightStart, journal: journal)
    await #expect(throws: EngineInvocationError.notImplemented(.author)) {
        try await invocation.run()
    }

    let events = try journal.events()

    // The Night is recorded first, so an Act that dies on its first line still says it opened.
    #expect(events.map(\.type) == [.nightOpened, .actStarted, .actIncomplete])
    #expect(events.map(\.act) == [.author, .author, .author])
    #expect(events.map(\.nightID) == [events[0].nightID, events[0].nightID, events[0].nightID])
    #expect(events[0].nightID != nil)

    guard case .actIncomplete(let reason) = events[2].event else {
        Issue.record("Third event is not ActIncomplete")
        return
    }
    #expect(reason.contains("Act 'author' is not implemented"))
}

@Test("An Act that stands down records ActStoodDown event")
func stoodDownActRecordsEvent() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))

    // Another invocation holds the lease
    let running = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)
    let runningRun = RunID()
    guard case .claimed(let holder) = try running.claimActLease(act: .build, runID: runningRun, mode: .real) else {
        Issue.record("The running Act did not claim the Project")
        return
    }

    // Now try to run a different Act, which should stand down
    await #expect(throws: EngineInvocationError.self) {
        try await runAct(.author, project: "alpha", in: directory)
    }

    // Should have recorded ActStoodDown
    let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)
    let events = try journal.events()
    #expect(events.count == 1)
    guard case .actStoodDown(let readHolder) = events[0].event else {
        Issue.record("Event is not ActStoodDown")
        return
    }
    #expect(readHolder == holder)
    #expect(events[0].act == .author)
}

@Test("An Act opens only its own Project's Journal, so events land only there")
func actOnlyWritesOwnJournal() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    try directory.writeValidProjectFile(id: "beta")

    let alphaID = try #require(ProjectID(rawValue: "alpha"))
    let betaID = try #require(ProjectID(rawValue: "beta"))

    // Run against alpha
    try await runAct(.author, project: "alpha", in: directory)

    // Alpha should have events
    let alphaJournal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: alphaID)
    let alphaEvents = try alphaJournal.events()
    #expect(Array(alphaEvents.map(\.type).prefix(2)) == [.nightOpened, .actStarted])
    #expect(alphaEvents.map(\.type).last == .actEnded)

    // Beta's Journal should not even exist (because the engine never opened it)
    let betaJournalPath = JournalStore.defaultFileURL(configurationDirectory: directory.url, id: betaID)
    #expect(!FileManager.default.fileExists(atPath: betaJournalPath.path))
}

@Test("Injected work that succeeds leaves [ActStarted, ActEnded], both stamped with the Act and runID")
func successfulWorkRecordsEndedEvent() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))
    let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)

    let invocation = EngineInvocation(
        act: .build,
        mode: .real,
        nightStart: nightStart,
        journal: journal,
        trigger: .forced,  // This test is about work execution and event recording, not predicates
        work: { _ in }
    )
    try await invocation.run()

    let events = try journal.events()
    #expect(events.map(\.type) == [.nightOpened, .actStarted, .actEnded])
    #expect(events.map(\.act) == [.build, .build, .build])
    #expect(events.map(\.runID) == [invocation.runID, invocation.runID, invocation.runID])
    #expect(try journal.currentActLease() == nil)
}

@Test("Injected work that throws leaves [ActStarted, ActIncomplete], lease released")
func failingWorkRecordsIncompleteEvent() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))
    let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)

    enum CustomError: Error {
        case testError
    }

    let invocation = EngineInvocation(
        act: .land,
        mode: .real,
        nightStart: nightStart,
        journal: journal,
        trigger: .forced,  // This test is about work execution and error handling, not predicates
        work: { _ in throw CustomError.testError }
    )

    await #expect(throws: CustomError.testError) {
        try await invocation.run()
    }

    let events = try journal.events()
    #expect(events.map(\.type) == [.nightOpened, .actStarted, .actIncomplete])
    guard case .actIncomplete(let reason) = events[2].event else {
        Issue.record("Third event is not ActIncomplete")
        return
    }
    #expect(reason.contains("testError"))
    #expect(try journal.currentActLease() == nil)
}

@Test("A dead predecessor's reclaim is recorded first, then the new run's own start and end")
func deadPredecessorReclaimIsRecordedInOrder() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))
    let dead = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)
    let deadRun = RunID()
    // Claimed eleven minutes ago and never heartbeated: crashed, or asleep past the TTL.
    _ = try dead.claimActLease(act: .author, runID: deadRun, mode: .real, now: Date().addingTimeInterval(-660))

    // Force the Act because this test is about lease reclaim and event ordering, not the trigger
    // predicate. The build Act's work has landed (P8.1): with no Feature in flight it completes idle.
    try await runAct(.build, project: "alpha", in: directory, force: true)

    let events = try dead.events()
    #expect(events.map(\.type) == [.leaseReclaimed, .nightOpened, .actStarted, .actIdle, .actEnded])
    #expect(events.allSatisfy { $0.act == .build })
    let runIDs = Set(events.compactMap(\.runID))
    #expect(runIDs.count == 1)
    #expect(!runIDs.contains(deadRun))
    guard case .leaseReclaimed(let previousRunID, let previousAct, _) = events[0].event else {
        Issue.record("The first event is not LeaseReclaimed")
        return
    }
    #expect(previousRunID == deadRun)
    #expect(previousAct == .author)
}

@Test("The Act lease is heartbeated while the work runs")
func actLeaseIsHeartbeatDuringWork() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))
    let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)
    // TTL must be >= 2s because whole-second storage loses up to 1s of precision
    let shortPolicy = LeasePolicy(heartbeatInterval: 0.05, timeToLive: 2)
    let runID = RunID()

    let invocation = EngineInvocation(
        act: .build,
        mode: .real,
        nightStart: nightStart,
        journal: journal,
        runID: runID,
        leasePolicy: shortPolicy,
        work: { _ in
            try await Task.sleep(for: Duration.milliseconds(3000))
            // Revalidating 3 s in, past a 2 s TTL, succeeds only because heartbeats kept the lease alive.
            _ = try journal.revalidateActLease(runID: runID)
        }
    )

    try await invocation.run()

    // Invocation must have completed without throwing (heartbeats kept the lease alive)
    let events = try journal.events()
    #expect(events.contains { $0.type == .actEnded })
}

@Test("A lost Act lease cancels the work and is recorded as ActIncomplete")
func lostActLeaseCancelsWork() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))
    let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)
    // A fast beat on the ruled 600 s TTL: the run's own lease cannot expire under it however long the
    // parallel suite stalls a hop, so the only way to lose it is the takeover, injected through `now:`.
    let policy = LeasePolicy(heartbeatInterval: 0.05, timeToLive: 600)
    let runID = RunID()
    let takerRunID = RunID()

    let invocation = EngineInvocation(
        act: .build,
        mode: .real,
        nightStart: nightStart,
        journal: journal,
        // Forced because this test is about lease loss and cancellation, not the trigger predicate.
        trigger: .forced,
        runID: runID,
        leasePolicy: policy,
        work: { _ in
            try await Task.sleep(for: Duration.milliseconds(100))

            // Have a second store "steal" the lease by claiming at a time past the run's expiry
            let takeover = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)
            _ = try takeover.claimActLease(
                act: .author, runID: takerRunID, mode: .real, policy: policy,
                now: Date().addingTimeInterval(policy.timeToLive + 60)
            )

            // Wait for the next beat to find the takeover and cancel us; the bound only stops a hang.
            for _ in 0..<3000 {
                try await Task.sleep(for: Duration.milliseconds(10))
                if Task.isCancelled { break }
            }
        }
    )

    do {
        try await invocation.run()
        Issue.record("Invocation did not throw actLeaseLost")
    } catch let error as JournalError {
        guard case .actLeaseLost(let errorRunID, let holder) = error else {
            Issue.record("Error is not actLeaseLost")
            return
        }
        #expect(errorRunID == runID)
        // The loss must be the takeover, not the run's own lease expiring under it.
        #expect(holder?.runID == takerRunID)
    }

    let events = try journal.events()
    let hasIncomplete = events.contains { $0.type == .actIncomplete }
    let hasEnded = events.contains { $0.type == .actEnded }
    #expect(hasIncomplete)
    #expect(!hasEnded)

    let current = try journal.currentActLease()
    #expect(current?.runID == takerRunID)
}
