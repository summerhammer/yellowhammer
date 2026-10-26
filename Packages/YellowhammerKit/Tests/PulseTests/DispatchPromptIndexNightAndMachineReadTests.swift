import Config
import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

@Suite("DispatchPromptIndex Night and Machine read tests")
struct PromptIndexNightMachineTests {
    @Test("Cover Night scope skipped empty state")
    func nightScopeSkippedEmptyState() async throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()

        let run = RunID()
        _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
        let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)
        _ = try journal.recordAuthoringNoWorkAvailable(
            nightID: opening.night.id, act: .author, runID: run, now: epoch
        )

        let index = try DispatchPromptIndex.read(
            journal: journal,
            store: store,
            projectID: fixture.projectID,
            scope: .night(nightID: opening.night.id),
            asOf: epoch
        )

        #expect(index.items.isEmpty)
        if case .skipped = index.emptyState {
            // Expected
        } else {
            Issue.record("Expected .skipped empty state, got \(String(describing: index.emptyState))")
        }
    }

    @Test("Cover breakdown walk with rejected route try followed by accepted one")
    func breakdownWalkRejectedAndAccepted() async throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()

        let run = RunID()
        _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
        let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)

        let rejectedRecordID = "rec-breakdown-1"
        let acceptedRecordID = "rec-breakdown-2"

        _ = try fixture.captureRecord(
            id: rejectedRecordID,
            pass: .breakdown,
            routeTry: 1,
            route: "claude/sonnet/medium",
            instruction: "Break down feature into cards (try 1)"
        )
        _ = try fixture.captureRecord(
            id: acceptedRecordID,
            pass: .breakdown,
            routeTry: 2,
            route: "codex/sol/medium",
            instruction: "Break down feature into cards (try 2)"
        )

        try appendBreakdownEvents(
            journal: journal,
            run: run,
            nightID: opening.night.id,
            rejectedID: rejectedRecordID,
            acceptedID: acceptedRecordID
        )

        let index = try DispatchPromptIndex.read(
            journal: journal,
            store: store,
            projectID: fixture.projectID,
            scope: .night(nightID: opening.night.id),
            asOf: epoch.addingTimeInterval(20)
        )

        #expect(index.emptyState == nil)
        #expect(index.items.count == 2)

        let rejectedItem = try #require(index.items.first { $0.id == rejectedRecordID })
        #expect(rejectedItem.pass == .breakdown)
        #expect(rejectedItem.routeTry == 1)
        #expect(rejectedItem.rejectionCause == .invalidOutput)
        #expect(rejectedItem.instruction == "Break down feature into cards (try 1)")

        let acceptedItem = try #require(index.items.first { $0.id == acceptedRecordID })
        #expect(acceptedItem.pass == .breakdown)
        #expect(acceptedItem.routeTry == 2)
        #expect(acceptedItem.rejectionCause == nil)
        #expect(acceptedItem.instruction == "Break down feature into cards (try 2)")
    }

    private func appendBreakdownEvents(
        journal: JournalStore,
        run: RunID,
        nightID: Int64,
        rejectedID: String,
        acceptedID: String
    ) throws {
        try journal.append(
            .promptCaptureRequested(
                recordID: rejectedID,
                pass: .breakdown,
                cardID: nil,
                issueID: "ALPHA-F",
                attemptID: nil,
                round: nil,
                ordinal: 1
            ),
            act: .author,
            runID: run,
            nightID: nightID,
            now: epoch
        )
        try journal.append(
            .authoringRouteRejected(
                pass: .breakdown,
                route: "claude/sonnet/medium",
                ordinal: 1,
                cause: .invalidOutput,
                reason: "Malformed JSON schema output"
            ),
            act: .author,
            runID: run,
            nightID: nightID,
            now: epoch.addingTimeInterval(5)
        )
        try journal.append(
            .promptCaptureRequested(
                recordID: acceptedID,
                pass: .breakdown,
                cardID: nil,
                issueID: "ALPHA-F",
                attemptID: nil,
                round: nil,
                ordinal: 2
            ),
            act: .author,
            runID: run,
            nightID: nightID,
            now: epoch.addingTimeInterval(10)
        )
        try journal.append(
            .authoringDispatched(
                pass: .breakdown,
                route: "codex/sol/medium",
                ordinal: 2,
                fixture: nil
            ),
            act: .author,
            runID: run,
            nightID: nightID,
            now: epoch.addingTimeInterval(15)
        )
    }

    @Test("Cover verifier dispatch in Night scope")
    func verifierDispatchNightScope() async throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()

        let run = RunID()
        _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
        let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)

        let verifierRecordID = "rec-verifier-1"
        _ = try fixture.captureRecord(
            id: verifierRecordID,
            pass: .verifier,
            routeTry: 1,
            route: "claude/sonnet/medium",
            instruction: "Verify the authored feature"
        )

        try journal.append(
            .promptCaptureRequested(
                recordID: verifierRecordID,
                pass: .verifier,
                cardID: nil,
                issueID: "ALPHA-F",
                attemptID: nil,
                round: nil,
                ordinal: 1
            ),
            act: .author,
            runID: run,
            nightID: opening.night.id,
            now: epoch
        )

        let index = try DispatchPromptIndex.read(
            journal: journal,
            store: store,
            projectID: fixture.projectID,
            scope: .night(nightID: opening.night.id),
            asOf: epoch
        )

        #expect(index.emptyState == nil)
        #expect(index.items.count == 1)
        let item = try #require(index.items.first)
        #expect(item.id == verifierRecordID)
        #expect(item.pass == .verifier)
        #expect(item.family == .verifier)
        #expect(item.instruction == "Verify the authored feature")
    }

    @Test("Cover machine grouping by run and CLI filtering")
    func machineGroupingByRun() async throws {
        let fixture = PromptIndexFixture()
        let store = fixture.makeStore()

        let run1ID = "run-claude-old"
        let run2ID = "run-claude-new"
        let run3ID = "run-codex"

        let time1 = epoch
        let time2 = epoch.addingTimeInterval(100)
        let time3 = epoch.addingTimeInterval(50)

        seedProbeRecords(store: store, run1ID: run1ID, run2ID: run2ID, run3ID: run3ID, times: [time1, time2, time3])

        // Filter by claude
        let claudeRuns = DispatchPromptIndex.machine(store: store, cli: "claude", asOf: epoch.addingTimeInterval(200))
        #expect(claudeRuns.count == 2)
        #expect(claudeRuns[0].runID == run2ID)
        #expect(claudeRuns[0].cli == "claude")
        #expect(claudeRuns[0].items.count == 3)
        #expect(claudeRuns[1].runID == run1ID)
        #expect(claudeRuns[1].cli == "claude")
        #expect(claudeRuns[1].items.count == 2)

        // Filter by codex
        let codexRuns = DispatchPromptIndex.machine(store: store, cli: "codex", asOf: epoch.addingTimeInterval(200))
        #expect(codexRuns.count == 1)
        #expect(codexRuns[0].runID == run3ID)
        #expect(codexRuns[0].cli == "codex")

        // Unfiltered (cli: nil) returns all runs, newest first
        let allRuns = DispatchPromptIndex.machine(store: store, cli: nil, asOf: epoch.addingTimeInterval(200))
        #expect(allRuns.count == 3)
        #expect(allRuns[0].runID == run2ID)
        #expect(allRuns[1].runID == run3ID)
        #expect(allRuns[2].runID == run1ID)

        // Empty machine index read
        let emptyDir = FileManager.default.temporaryDirectory
            .appending(component: "yh-empty-machine-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: emptyDir) }
        let emptyRead = DispatchPromptIndex.read(
            configurationDirectory: emptyDir,
            scope: .machine(),
            asOf: epoch
        )
        guard case .index(let emptyIndex) = emptyRead else {
            Issue.record("Expected .index read, got \(emptyRead)")
            return
        }
        #expect(emptyIndex.items.isEmpty)
        #expect(emptyIndex.emptyState == .noDiagnosticDispatchesRecorded)
    }

    private func seedProbeRecords(
        store: DispatchPromptStore,
        run1ID: String,
        run2ID: String,
        run3ID: String,
        times: [Date]
    ) {
        let time1 = times[0]
        let time2 = times[1]
        let time3 = times[2]
        for (index, family) in [PromptFamily.unattendedProbe, .sessionResumptionProbe].enumerated() {
            let rec = DispatchPromptRecord(
                id: "rec-c1-\(index)",
                provenance: DispatchProvenance(recordID: "rec-c1-\(index)", family: family, runID: run1ID),
                route: "claude/sonnet/medium",
                pass: .worker,
                dispatchedAt: time1,
                defaultVersion: 1,
                projectInstructions: .absent,
                session: .new,
                instruction: "Probe \(family.rawValue) for claude 1",
                outputSchema: nil,
                launch: .launched
            )
            let capture = store.capture(rec)
            #expect(capture == .recorded(id: rec.id))
        }

        let run2Families: [PromptFamily] = [.unattendedProbe, .sessionResumptionProbe, .stateContainmentProbe]
        for (index, family) in run2Families.enumerated() {
            let rec = DispatchPromptRecord(
                id: "rec-c2-\(index)",
                provenance: DispatchProvenance(recordID: "rec-c2-\(index)", family: family, runID: run2ID),
                route: "claude/sonnet/medium",
                pass: .worker,
                dispatchedAt: time2,
                defaultVersion: 1,
                projectInstructions: .absent,
                session: .new,
                instruction: "Probe \(family.rawValue) for claude 2",
                outputSchema: nil,
                launch: .launched
            )
            let capture = store.capture(rec)
            #expect(capture == .recorded(id: rec.id))
        }

        let recCodex = DispatchPromptRecord(
            id: "rec-codex-1",
            provenance: DispatchProvenance(recordID: "rec-codex-1", family: .unattendedProbe, runID: run3ID),
            route: "codex/sol/medium",
            pass: .worker,
            dispatchedAt: time3,
            defaultVersion: 1,
            projectInstructions: .absent,
            session: .new,
            instruction: "Probe for codex",
            outputSchema: nil,
            launch: .launched
        )
        let captureCodex = store.capture(recCodex)
        #expect(captureCodex == .recorded(id: recCodex.id))
    }
}
