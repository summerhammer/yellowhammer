import Config
import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

struct SeededAttempt {
    let cardID: Int64
    let attemptID: Int64
    let runID: RunID
}

struct PromptIndexFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID
    var now: Date

    init(now: Date = epoch) {
        self.now = now
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-prompt-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        projectID = ProjectID(rawValue: "project-test")!
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func openJournal() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }

    func makeStore() -> DispatchPromptStore {
        let currentTime = now
        return DispatchPromptStore(
            rootDirectory: DispatchPromptStore.rootDirectory(configurationDirectory: directory),
            now: { currentTime }
        )
    }

    func seedAttempt(
        journal: JournalStore,
        issueID: String = "ALPHA-1",
        mode: NightMode = .real
    ) throws -> SeededAttempt {
        let feature = try insertFeature(journal, issueID: "ALPHA-F")
        let cardID = try insertCard(journal, cycleID: feature.cycleID, issueID: issueID)
        let run = RunID()
        _ = try journal.claimActLease(act: .build, runID: run, mode: mode, now: epoch)
        let attempt = try journal.recordAttempt(
            cardID: cardID, route: route(), routeSource: "entry", runID: run, now: epoch
        )
        return SeededAttempt(cardID: cardID, attemptID: attempt.id, runID: run)
    }

    func captureRecord(
        id: String,
        pass: RunPass = .worker,
        cardID: Int64 = 1,
        issueID: String = "ALPHA-1",
        attemptID: Int64 = 1,
        round: Int? = 1,
        routeTry: Int? = 1,
        route: String = "claude/sonnet/medium",
        session: DispatchSession = .new,
        dispatchedAt: Date? = nil,
        instruction: String = "Fix the bug in backend",
        outputSchema: String? = "{\"type\": \"object\"}",
        launch: DispatchLaunch = .launched
    ) throws -> DispatchPromptRecord {
        let store = makeStore()
        let provenance = DispatchProvenance(
            recordID: id,
            family: PromptFamily(pass: pass) ?? .worker,
            projectID: projectID.rawValue,
            featureIssueID: "ALPHA-F",
            workCardIssueID: issueID,
            cardID: cardID,
            attemptID: attemptID,
            round: round,
            routeTry: routeTry
        )
        let record = DispatchPromptRecord(
            id: id,
            provenance: provenance,
            route: route,
            pass: pass,
            dispatchedAt: dispatchedAt ?? now,
            defaultVersion: 1,
            projectInstructions: .absent,
            session: session,
            instruction: instruction,
            outputSchema: outputSchema,
            launch: launch
        )
        let capture = store.capture(record)
        guard case .recorded = capture else {
            throw PromptTestError.captureFailed
        }
        return record
    }

    enum PromptTestError: Error {
        case captureFailed
    }
}

@Suite("DispatchPromptIndex read tests")
struct DispatchPromptIndexReadTests {
    @Test("Cover a recorded dispatch")
    func recordedDispatch() async throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()
        let seed = try fixture.seedAttempt(journal: journal)

        let recordID = "rec-recorded-1"
        _ = try fixture.captureRecord(id: recordID, cardID: seed.cardID, attemptID: seed.attemptID)

        try journal.append(
            .promptCaptureRequested(
                recordID: recordID,
                pass: .worker,
                cardID: seed.cardID,
                issueID: "ALPHA-1",
                attemptID: seed.attemptID,
                round: 1,
                ordinal: 1
            ),
            act: .build,
            runID: seed.runID,
            now: epoch
        )

        let index = try DispatchPromptIndex.read(
            journal: journal,
            store: store,
            projectID: fixture.projectID,
            scope: .attempt(cardID: seed.cardID, attemptID: seed.attemptID),
            asOf: epoch
        )

        #expect(index.emptyState == nil)
        #expect(index.items.count == 1)
        let item = try #require(index.items.first)
        #expect(item.id == recordID)
        #expect(item.pass == .worker)
        #expect(item.round == 1)
        #expect(item.session == .new)
        #expect(item.instruction == "Fix the bug in backend")
        #expect(item.outputSchema == "{\"type\": \"object\"}")
        if case .recorded(let rec) = item.state {
            #expect(rec.id == recordID)
            #expect(rec.launch == .launched)
        } else {
            Issue.record("Expected .recorded state, got \(item.state)")
        }
    }

    @Test("Cover expiry at 30 days")
    func expiryAt30Days() async throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let seed = try fixture.seedAttempt(journal: journal)

        let recordID = "rec-expired-1"
        _ = try fixture.captureRecord(
            id: recordID, cardID: seed.cardID, attemptID: seed.attemptID, dispatchedAt: epoch
        )

        try journal.append(
            .promptCaptureRequested(
                recordID: recordID,
                pass: .worker,
                cardID: seed.cardID,
                issueID: "ALPHA-1",
                attemptID: seed.attemptID,
                round: 1,
                ordinal: 1
            ),
            act: .build,
            runID: seed.runID,
            now: epoch
        )

        let future = epoch.addingTimeInterval(DispatchPromptRecord.retention + 1)
        let store = DispatchPromptStore(
            rootDirectory: DispatchPromptStore.rootDirectory(configurationDirectory: fixture.directory),
            now: { future }
        )

        let index = try DispatchPromptIndex.read(
            journal: journal,
            store: store,
            projectID: fixture.projectID,
            scope: .attempt(cardID: seed.cardID, attemptID: seed.attemptID),
            asOf: future
        )

        #expect(index.items.count == 1)
        let item = try #require(index.items.first)
        #expect(item.instruction == nil)
        #expect(item.outputSchema == nil)
        if case .expired(let dispatchedAt) = item.state {
            #expect(dispatchedAt == epoch)
        } else {
            Issue.record("Expected .expired state, got \(item.state)")
        }
    }

    @Test("Cover a tombstone")
    func tombstoneRecord() async throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()
        let seed = try fixture.seedAttempt(journal: journal)

        let recordID = "rec-tombstone-1"
        _ = try fixture.captureRecord(id: recordID, cardID: seed.cardID, attemptID: seed.attemptID)
        _ = store.delete(ids: [recordID], in: .project(fixture.projectID))

        try journal.append(
            .promptCaptureRequested(
                recordID: recordID,
                pass: .worker,
                cardID: seed.cardID,
                issueID: "ALPHA-1",
                attemptID: seed.attemptID,
                round: 1,
                ordinal: 1
            ),
            act: .build,
            runID: seed.runID,
            now: epoch
        )

        let index = try DispatchPromptIndex.read(
            journal: journal,
            store: store,
            projectID: fixture.projectID,
            scope: .attempt(cardID: seed.cardID, attemptID: seed.attemptID),
            asOf: epoch
        )

        #expect(index.items.count == 1)
        let item = try #require(index.items.first)
        #expect(item.instruction == nil)
        if case .deleted = item.state {
            // Success
        } else {
            Issue.record("Expected .deleted state, got \(item.state)")
        }
    }

    @Test("Cover unavailable")
    func unavailableRecord() async throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()
        let seed = try fixture.seedAttempt(journal: journal)

        let recordID = "rec-missing-file"
        try journal.append(
            .promptCaptureRequested(
                recordID: recordID,
                pass: .worker,
                cardID: seed.cardID,
                issueID: "ALPHA-1",
                attemptID: seed.attemptID,
                round: 1,
                ordinal: 1
            ),
            act: .build,
            runID: seed.runID,
            now: epoch
        )

        let index = try DispatchPromptIndex.read(
            journal: journal,
            store: store,
            projectID: fixture.projectID,
            scope: .attempt(cardID: seed.cardID, attemptID: seed.attemptID),
            asOf: epoch
        )

        #expect(index.items.count == 1)
        let item = try #require(index.items.first)
        #expect(item.instruction == nil)
        if case .unavailable = item.state {
            // Success
        } else {
            Issue.record("Expected .unavailable state, got \(item.state)")
        }
    }

    @Test("Cover rehearsal")
    func rehearsalPass() async throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()
        let seed = try fixture.seedAttempt(journal: journal, mode: .rehearsal)

        try journal.append(
            .rehearsalFixtureAnswered(
                cardID: seed.cardID,
                issueID: "ALPHA-1",
                attemptID: seed.attemptID,
                pass: .worker,
                fixture: "worker-success.json"
            ),
            act: .build,
            runID: seed.runID,
            now: epoch
        )

        let index = try DispatchPromptIndex.read(
            journal: journal,
            store: store,
            projectID: fixture.projectID,
            scope: .attempt(cardID: seed.cardID, attemptID: seed.attemptID),
            asOf: epoch
        )

        #expect(index.items.count == 1)
        let item = try #require(index.items.first)
        #expect(item.instruction == nil)
        if case .rehearsal(let fixtureName) = item.state {
            #expect(fixtureName == "worker-success.json")
        } else {
            Issue.record("Expected .rehearsal state, got \(item.state)")
        }
    }

    @Test("Cover legacy history without prompt capture")
    func legacyHistory() async throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()
        let seed = try fixture.seedAttempt(journal: journal)

        try journal.append(
            .agentCLIProcessSpawned(
                cardID: seed.cardID,
                issueID: "ALPHA-1",
                attemptID: seed.attemptID,
                pass: .worker,
                cli: "claude"
            ),
            act: .build,
            runID: seed.runID,
            now: epoch
        )

        let index = try DispatchPromptIndex.read(
            journal: journal,
            store: store,
            projectID: fixture.projectID,
            scope: .attempt(cardID: seed.cardID, attemptID: seed.attemptID),
            asOf: epoch
        )

        #expect(index.items.isEmpty)
        #expect(index.emptyState == .legacy)
    }

    @Test("Cover no dispatches yet")
    func noDispatchesYet() async throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()
        let seed = try fixture.seedAttempt(journal: journal)

        let index = try DispatchPromptIndex.read(
            journal: journal,
            store: store,
            projectID: fixture.projectID,
            scope: .attempt(cardID: seed.cardID, attemptID: seed.attemptID),
            asOf: epoch
        )

        #expect(index.items.isEmpty)
        #expect(index.emptyState == .noDispatchesYet)
    }

    private func appendWorkerPass(
        journal: JournalStore, recordID: String, seed: SeededAttempt, round: Int, time: Date
    ) throws {
        try journal.append(
            .promptCaptureRequested(
                recordID: recordID,
                pass: .worker,
                cardID: seed.cardID,
                issueID: "ALPHA-1",
                attemptID: seed.attemptID,
                round: round,
                ordinal: 1
            ),
            act: .build,
            runID: seed.runID,
            now: time
        )
    }

    @Test("Cover a resumed worker in Round 2")
    func resumedWorkerRound2() async throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()
        let seed = try fixture.seedAttempt(journal: journal)

        let rec1 = "rec-round-1"
        let rec2 = "rec-round-2"
        _ = try fixture.captureRecord(
            id: rec1, cardID: seed.cardID, attemptID: seed.attemptID, round: 1, session: .new
        )
        _ = try fixture.captureRecord(
            id: rec2, cardID: seed.cardID, attemptID: seed.attemptID, round: 2, session: .resumed,
            instruction: "Address reviewer changes in backend"
        )

        try appendWorkerPass(journal: journal, recordID: rec1, seed: seed, round: 1, time: epoch)
        try appendWorkerPass(journal: journal, recordID: rec2, seed: seed, round: 2, time: epoch.addingTimeInterval(60))

        let index = try DispatchPromptIndex.read(
            journal: journal,
            store: store,
            projectID: fixture.projectID,
            scope: .attempt(cardID: seed.cardID, attemptID: seed.attemptID),
            asOf: epoch.addingTimeInterval(60)
        )

        #expect(index.items.count == 2)
        let item1 = index.items[0]
        let item2 = index.items[1]

        #expect(item1.id == rec1)
        #expect(item1.round == 1)
        #expect(item1.session == .new)
        #expect(!item1.isResumed)

        #expect(item2.id == rec2)
        #expect(item2.round == 2)
        #expect(item2.session == .resumed)
        #expect(item2.isResumed)
        #expect(item2.instruction == "Address reviewer changes in backend")
    }
}
