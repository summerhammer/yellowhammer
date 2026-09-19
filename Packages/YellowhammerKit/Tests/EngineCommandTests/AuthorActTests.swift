import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Synchronization
import Testing

// roadmap P9.1: the author Act's skeleton, in order — skip when a Feature is already in flight for
// this Project, run the predecessor-ancestry gate (the real gate is P9.2, injected here), select and
// author (P9.3–P9.7, injected here), and record the idle verdict when nothing was selectable. Each of
// these is a quiet Night, not a failure: the Act returns normally and the reason is on the Night Card.

let authorActNightStart = NightStart(rawValue: "2026-09-15")!

/// Shared between a gate fake and an authoring fake to assert call order.
final class AuthorActCallLog: Sendable {
    private let state = Mutex<[String]>([])

    func record(_ tag: String) {
        state.withLock { $0.append(tag) }
    }

    var entries: [String] { state.withLock { $0 } }
}

/// A `PredecessorGate` that always answers the same outcome, and records whether it was called.
final class ScriptedPredecessorGate: PredecessorGate, Sendable {
    private let called = Mutex(false)
    private let outcome: PredecessorGateOutcome
    private let log: AuthorActCallLog?

    init(outcome: PredecessorGateOutcome, log: AuthorActCallLog? = nil) {
        self.outcome = outcome
        self.log = log
    }

    var wasCalled: Bool { called.withLock { $0 } }

    func check(_ context: ActContext) async throws -> PredecessorGateOutcome {
        called.withLock { $0 = true }
        log?.record("gate")
        return outcome
    }
}

/// A `FeatureAuthoring` that always answers the same outcome, and records whether it was called.
final class ScriptedFeatureAuthoring: FeatureAuthoring, Sendable {
    private let called = Mutex(false)
    private let outcome: FeatureAuthoringOutcome
    private let log: AuthorActCallLog?

    init(outcome: FeatureAuthoringOutcome, log: AuthorActCallLog? = nil) {
        self.outcome = outcome
        self.log = log
    }

    var wasCalled: Bool { called.withLock { $0 } }

    func selectAndAuthor(_ context: ActContext) async throws -> FeatureAuthoringOutcome {
        called.withLock { $0 = true }
        log?.record("authoring")
        return outcome
    }
}

@Suite("Author Act")
struct AuthorActTests {
    @Test("A Feature already in flight is skipped: nothing is authored, the reason names the Feature")
    func skipsWhenFeatureInFlight() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        // Every Card finished (Blocked counts as finished), so the scheduled trigger is met even
        // though a Feature is in flight.
        _ = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .blocked
        )

        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let gate = ScriptedPredecessorGate(outcome: .landed)
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        let invocation = EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: authorActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, board: board,
            work: AuthorAct(predecessorGate: gate, authoring: authoring).work
        )
        try await invocation.run()

        #expect(!gate.wasCalled)
        #expect(!authoring.wasCalled)

        let events = try journal.events()
        let skipEvent = try #require(events.first { $0.type == .authoringSkippedFeatureInFlight })
        guard case .authoringSkippedFeatureInFlight(let issueID) = skipEvent.event else {
            Issue.record("expected authoringSkippedFeatureInFlight")
            return
        }
        #expect(issueID == "FEAT-1")
        #expect(events.map(\.type).last == .actEnded)

        let issue = try #require(await boards.writing.liveIssues.first)
        let description = try #require(issue.description)
        #expect(description.contains("FEAT-1"))
        #expect(description.contains("quiet Night"))
    }

    @Test("A forced trigger and .forcedForFeature still skip when a Feature is in flight")
    func forcedTriggersStillSkip() async throws {
        for trigger: ActTrigger in [.forced, .forcedForFeature(try #require(FeatureName(rawValue: "OTHER")))] {
            let fixture = try OutboxJournalFixture()
            let journal = try fixture.open()
            let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-2")
            let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
            // Unfinished Cards this time: forcing must still refuse a second Feature in flight.
            _ = try insertReconcilerCard(
                journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo
            )

            let gate = ScriptedPredecessorGate(outcome: .landed)
            let authoring = ScriptedFeatureAuthoring(outcome: .authored)
            let invocation = EngineInvocation(
                act: .author, mode: .rehearsal, nightStart: authorActNightStart, journal: journal,
                trigger: trigger, runID: RunID(),
                work: AuthorAct(predecessorGate: gate, authoring: authoring).work
            )
            try await invocation.run()

            #expect(!gate.wasCalled)
            #expect(!authoring.wasCalled)
            let events = try journal.events().map(\.type)
            #expect(events.contains(.authoringSkippedFeatureInFlight))
        }
    }

    @Test("A predecessor not landed stops authoring: no Worktree, no Attempt, the reason names it")
    func predecessorNotLandedStopsAuthoring() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let gate = ScriptedPredecessorGate(
            outcome: .notLanded(predecessorIssueID: "FEAT-0", repositories: ["backend", "mobile"])
        )
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        let invocation = EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: authorActNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            work: AuthorAct(predecessorGate: gate, authoring: authoring).work
        )
        try await invocation.run()

        #expect(gate.wasCalled)
        #expect(!authoring.wasCalled)
        #expect(try journal.inFlightFeature() == nil)

        let events = try journal.events()
        let event = try #require(events.first { $0.type == .authoringPredecessorNotLanded })
        guard case .authoringPredecessorNotLanded(let issueID, let repositories) = event.event else {
            Issue.record("expected authoringPredecessorNotLanded")
            return
        }
        #expect(issueID == "FEAT-0")
        #expect(repositories == ["backend", "mobile"])

        let issue = try #require(await boards.writing.liveIssues.first)
        let description = try #require(issue.description)
        #expect(description.contains("FEAT-0"))
        #expect(description.contains("backend"))
        #expect(description.contains("mobile"))
    }

    @Test("Nothing selectable to author records the idle verdict, visible on the Night Card")
    func noWorkAvailableRecordsIdleVerdict() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let gate = ScriptedPredecessorGate(outcome: .landed)
        let authoring = ScriptedFeatureAuthoring(outcome: .noWorkAvailable)

        let invocation = EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: authorActNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            work: AuthorAct(predecessorGate: gate, authoring: authoring).work
        )
        try await invocation.run()

        #expect(gate.wasCalled)
        #expect(authoring.wasCalled)
        let events = try journal.events().map(\.type)
        #expect(events.contains(.authoringNoWorkAvailable))
        #expect(try journal.currentNight()?.verdict == .idle)

        let issue = try #require(await boards.writing.liveIssues.first)
        let description = try #require(issue.description)
        #expect(description.contains("AuthoringNoWorkAvailable"))
    }

    @Test("Authoring runs after the gate clears, and no quiet event is recorded")
    func authoredRunsAfterGateClears() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let log = AuthorActCallLog()
        let gate = ScriptedPredecessorGate(outcome: .landed, log: log)
        let authoring = ScriptedFeatureAuthoring(outcome: .authored, log: log)

        let invocation = EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: authorActNightStart, journal: journal,
            trigger: .forced, runID: RunID(),
            work: AuthorAct(predecessorGate: gate, authoring: authoring).work
        )
        try await invocation.run()

        #expect(gate.wasCalled)
        #expect(authoring.wasCalled)
        #expect(log.entries == ["gate", "authoring"])

        let events = try journal.events().map(\.type)
        #expect(!events.contains(.authoringSkippedFeatureInFlight))
        #expect(!events.contains(.authoringPredecessorNotLanded))
        #expect(!events.contains(.authoringNoWorkAvailable))
        #expect(try journal.currentNight()?.verdict == nil)
    }

    @Test("With no authoring seam wired, the Act throws notImplemented rather than falsely idling")
    func nilAuthoringThrowsNotImplemented() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()

        let invocation = EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: authorActNightStart, journal: journal,
            trigger: .forced, runID: RunID(),
            work: AuthorAct(predecessorGate: nil, authoring: nil).work
        )

        await #expect(throws: EngineInvocationError.self) {
            try await invocation.run()
        }

        let events = try journal.events().map(\.type)
        #expect(events.last == .actIncomplete)
    }
}

@Suite("Night Card authoring findings")
struct NightCardAuthoringFindingsTests {
    @Test("No lines renders identically to the pre-P9.1 block")
    func noLinesRendersUnchanged() throws {
        let night = NightRecord(
            id: 1, projectID: try #require(ProjectID(rawValue: "fixture")), nightStart: authorActNightStart,
            mode: .rehearsal, state: .opened, nightCardIssueID: nil,
            openedAt: Date(timeIntervalSince1970: 1_800_000_000), completedAt: nil, closeReason: nil, verdict: nil
        )
        let projectID = try #require(ProjectID(rawValue: "fixture"))
        let withDefault = NightCardBlock.opened(night: night, projectID: projectID)
        let withEmpty = NightCardBlock.opened(night: night, projectID: projectID, authoringFindings: [])
        #expect(withDefault == withEmpty)
        #expect(!withDefault.contains("**Authoring:**"))
    }

    @Test("Every distinct line passed in appears in the opened block's authoring section")
    func distinctLinesAppearInOpenedBlock() throws {
        let night = NightRecord(
            id: 1, projectID: try #require(ProjectID(rawValue: "fixture")), nightStart: authorActNightStart,
            mode: .rehearsal, state: .opened, nightCardIssueID: nil,
            openedAt: Date(timeIntervalSince1970: 1_800_000_000), completedAt: nil, closeReason: nil, verdict: nil
        )
        let projectID = try #require(ProjectID(rawValue: "fixture"))
        // Dedup itself is `NightCardMaintenance.recordAuthoring`'s job, reading the Journal's events;
        // the block renders whatever lines it is handed, one bullet each.
        let rendered = NightCardBlock.opened(
            night: night, projectID: projectID, authoringFindings: ["first line", "second line"]
        )
        #expect(rendered.contains("**Authoring:**"))
        #expect(rendered.contains("- first line"))
        #expect(rendered.contains("- second line"))
    }

    @Test("A forced re-run recording the same quiet reason twice in one Night shows it once on the Card")
    func repeatedQuietReasonIsDeduplicatedOnTheCard() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-9")
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .blocked
        )
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)

        for _ in 0..<2 {
            try await EngineInvocation(
                act: .author, mode: .rehearsal, nightStart: authorActNightStart, journal: journal,
                trigger: .forced, runID: RunID(), board: board,
                work: AuthorAct(predecessorGate: nil, authoring: nil).work
            ).run()
        }

        let events = try journal.events(ofType: .authoringSkippedFeatureInFlight)
        #expect(events.count == 2)

        let issue = try #require(await boards.writing.liveIssues.first)
        let description = try #require(issue.description)
        #expect(description.components(separatedBy: "FEAT-9").count - 1 == 1)
    }

    @Test("The completed block includes authoring findings")
    func completedBlockIncludesFindings() throws {
        let night = NightRecord(
            id: 1, projectID: try #require(ProjectID(rawValue: "fixture")), nightStart: authorActNightStart,
            mode: .rehearsal, state: .closed, nightCardIssueID: nil,
            openedAt: Date(timeIntervalSince1970: 1_800_000_000),
            completedAt: Date(timeIntervalSince1970: 1_800_003_600), closeReason: .nightEnd, verdict: .idle
        )
        let projectID = try #require(ProjectID(rawValue: "fixture"))
        let rendered = NightCardBlock.completed(
            night: night, projectID: projectID, authoringFindings: ["a finding"]
        )
        #expect(rendered.contains("**Authoring:**"))
        #expect(rendered.contains("a finding"))
    }
}
