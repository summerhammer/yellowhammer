import ArgumentParser
import Domain
import Engine
@testable import EngineCommand
import Foundation
import Journal
import Testing

// shift-scheduling/fire-an-act-on-schedule: an Act is scoped to one Project and opens only its Journal;
// an Act firing while another Act of the same Project runs does not corrupt state. ADR-002: an invocation
// holds no handle on sibling Projects.

private let nightStart = NightStart(rawValue: "2026-09-15")!

/// Parses `yh <act> --project <id>` and runs it against the given configuration directory.
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
    // No Board bound: this suite is about lease/Journal mechanics, not the Night Card (NightCardTests).
    try await command.makeInvocation(configurationDirectory: directory.url, now: Date(), bindBoard: nil).run()
}

private func journalFiles(in directory: borrowing ConfigurationDirectory) throws -> [String] {
    let journals = directory.url.appending(component: "journals", directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: journals.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: journals.path).sorted()
}

@Test("An Act opens only its own Project's Journal, never a sibling's", arguments: Act.allCases)
func actOpensOnlyItsOwnJournal(_ act: Act) async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    try directory.writeValidProjectFile(id: "beta")

    // Force build and land Acts because this test is about Journal scoping, not trigger predicates.
    // Every Act's work has landed (P8.1, P9.11, P10.1): on an empty Journal each completes doing
    // nothing (the author Act's selection finds no Route it can run and ends as an authoring fault).
    try await runAct(act, project: "alpha", in: directory, force: act != .author)

    #expect(try journalFiles(in: directory) == ["alpha.db"])
}

@Test("A refused Act creates no Journal", arguments: Act.allCases)
func refusedActCreatesNoJournal(_ act: Act) async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()

    await #expect(throws: ProjectResolutionError.self) {
        try await runAct(act, project: "absent", in: directory)
    }

    #expect(try journalFiles(in: directory) == [])
}

@Test("An Act firing while another Act of the same Project runs stands down, out loud", arguments: Act.allCases)
func overlappingActStandsDown(_ act: Act) async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))
    // Another invocation of the same Project, mid-Act: it holds the Act-scoped lease and is heartbeating.
    let running = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)
    let runningRun = RunID()
    guard case .claimed(let holder) = try running.claimActLease(act: .build, runID: runningRun, mode: .real) else {
        Issue.record("The running Act did not claim the Project")
        return
    }

    let error: EngineInvocationError
    do {
        try await runAct(act, project: "alpha", in: directory)
        Issue.record("The overlapping Act was not refused")
        return
    } catch let refused as EngineInvocationError {
        error = refused
    }

    #expect(error == .actLeaseHeld(act: act, projectID: projectID, by: holder))
    #expect(RootCommand.exitCode(for: error) == ExitCode(1))
    let message = RootCommand.fullMessage(for: error)
    #expect(message.contains("stood down"))
    #expect(message.contains("'alpha'"))
    #expect(message.contains(runningRun.rawValue))
    #expect(message.contains("No Act was run"))
    // The running Act still holds the Project, untouched.
    #expect(try running.currentActLease() == holder)
    try running.heartbeatActLease(runID: runningRun)
}

@Test("An Act whose predecessor died takes the Project over once the lease has expired")
func deadPredecessorIsReclaimed() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))
    let dead = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)
    // Claimed eleven minutes ago and never heartbeated: crashed, or asleep past the TTL.
    _ = try dead.claimActLease(act: .build, runID: RunID(), mode: .real, now: Date().addingTimeInterval(-660))

    // Force the Act because this test is about lease reclaim and takeover, not the trigger predicate.
    // The build Act's work has landed (P8.1): on an empty Journal it completes doing nothing.
    try await runAct(.build, project: "alpha", in: directory, force: true)

    // The new run claimed the Project and released it on exit.
    #expect(try dead.currentActLease() == nil)
}

@Test("An invocation releases the Project when it exits, even by throwing", arguments: Act.allCases)
func invocationReleasesOnExit(_ act: Act) async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))

    // Force build and land Acts because this test is about lease release, not trigger predicates.
    // Every Act's work has landed (P8.1, P9.11, P10.1): on an empty Journal each completes doing nothing.
    try await runAct(act, project: "alpha", in: directory, force: act != .author)

    let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)
    #expect(try journal.currentActLease() == nil)
    // And so the next firing of the same Project is not held off.
    try await runAct(act, project: "alpha", in: directory, force: true)
}

@Test("An invocation is scoped to the Project whose Journal it was given")
func invocationIsScopedToItsJournal() throws {
    let directory = ConfigurationDirectory()
    let projectID = try #require(ProjectID(rawValue: "alpha"))
    let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)

    let invocation = EngineInvocation(act: .build, mode: .rehearsal, nightStart: nightStart, journal: journal)

    #expect(invocation.projectID == projectID)
    #expect(invocation.mode == .rehearsal)
    #expect(invocation.leasePolicy == .ruled)
    #expect(invocation.nightStart == nightStart)
    #expect(!invocation.closesNight)
}
