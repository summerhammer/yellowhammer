import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// roadmap P9.8 (glossary: Authoring Halt, Refusal): the two authoring stops end to end — one clock over
// both, one Feature Issue however a Feature stops, a citation answering a Refusal, and the vocabulary
// each kind uses. Never asserts model-authored content, only the wiring.

private func stopContext(
    _ journal: JournalStore, night: String, boards: NightCardTestBoards, previous: RunID? = nil,
    boardOperator: BoardObjectID? = nil
) throws -> (context: ActContext, runID: RunID) {
    if let previous {
        try journal.releaseActLease(runID: previous)
    }
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .rehearsal) else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    let opening = try journal.openNight(
        nightStart: try #require(NightStart(rawValue: night)), mode: .rehearsal, act: .author, runID: runID
    )
    let outbox = Outbox(journal: journal, board: boards.writing, runID: runID, act: .author, nightID: opening.night.id)
    let actBoard = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
    let context = ActContext(
        act: .author, mode: .rehearsal, trigger: .forced, runID: runID, journal: journal,
        night: opening.night, outbox: outbox, board: actBoard, boardOperator: boardOperator,
        mainlines: selectionMainlines(),
        workspace: nil, repositories: selectionRepositories()
    )
    return (context, runID)
}

private let seam = AuthoringHaltCause.noBackwardCompatibleSeam(seam: "the shared endpoint")
private let finding = RefusalFinding(
    uncitable: [UncitableClause(
        level: "card", cardTitle: "Backend one", text: "Ghost clause", citation: "epic/ghost", reason: "no such story"
    )],
    reselectionDepth: 2
)

@Suite("Authoring stops end to end (P9.8)")
struct AuthoringStopTests {
    private func name(_ raw: String) throws -> FeatureName { try #require(FeatureName(rawValue: raw)) }

    @Test("A configured Operator receives a halted Feature Issue; a missing identity leaves it unassigned")
    func stopAssignment() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let assigned = BoardObjectID(rawValue: "linear-user-1")
        let (night1, run1) = try stopContext(
            journal, night: "2026-09-15", boards: boards, boardOperator: assigned
        )
        _ = try await AuthoringHalt.record(feature: try name("FEAT-H"), cause: seam, context: night1)
        let (night2, _) = try stopContext(journal, night: "2026-09-16", boards: boards, previous: run1)
        _ = try await RefusalRecording.record(feature: try name("FEAT-R"), finding: finding, context: night2)
        let issues = await boards.writing.liveIssues
        #expect(issues.first { $0.title == "FEAT-H" }?.assignee == assigned)
        #expect(issues.first { $0.title == "FEAT-R" }?.assignee == nil)
    }

    @Test("A halt and a Refusal expire on the same clock: one Blocked / unanswered update each")
    func bothExpireOnOneClock() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()

        let (night1, run1) = try stopContext(journal, night: "2026-09-15", boards: boards)
        _ = try await AuthoringHalt.record(feature: try name("FEAT-H"), cause: seam, context: night1)
        _ = try await RefusalRecording.record(feature: try name("FEAT-R"), finding: finding, context: night1)
        var run = run1
        for night in ["2026-09-16", "2026-09-17"] {
            let (context, next) = try stopContext(journal, night: night, boards: boards, previous: run)
            try await UnansweredPositionClock.run(context: context, unansweredNightsMax: 1)
            run = next
        }

        let halt = try #require(try journal.authoringHalts(feature: try name("FEAT-H")).first)
        let refusal = try #require(try journal.refusals(feature: try name("FEAT-R")).first)
        #expect(halt.state == .expired)
        #expect(refusal.state == .expired)
        #expect(await boards.writing.updateCalls == 2)
        let blocked = try await blockedStateID(boards)
        for issueID in [try #require(halt.issueID), try #require(refusal.issueID)] {
            let issue = try #require(await boards.writing.liveIssues.first { $0.id.rawValue == issueID })
            #expect(issue.workflowState == blocked)
            #expect(issue.labels.contains(try #require(boards.ids["unanswered"])))
        }
    }

    @Test("A citation after expiry answers the Refusal and moves the Feature Issue to Todo, once")
    func citationAfterExpiry() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let (night1, run1) = try stopContext(journal, night: "2026-09-15", boards: boards)
        _ = try await RefusalRecording.record(feature: try name("FEAT-R"), finding: finding, context: night1)
        let (night2, run2) = try stopContext(journal, night: "2026-09-16", boards: boards, previous: run1)
        try await UnansweredPositionClock.run(context: night2, unansweredNightsMax: 0)
        #expect(try journal.refusals(feature: try name("FEAT-R")).first?.state == .expired)
        let updatesBefore = await boards.writing.updateCalls

        let (night3, _) = try stopContext(journal, night: "2026-09-17", boards: boards, previous: run2)
        #expect(try await RefusalAnswer.apply(feature: try name("FEAT-R"), citation: "epic/story", context: night3))
        #expect(try await !RefusalAnswer.apply(feature: try name("FEAT-R"), citation: "epic/story", context: night3))

        let refusal = try #require(try journal.refusals(feature: try name("FEAT-R")).first)
        #expect(refusal.state == .answered)
        #expect(await boards.writing.updateCalls == updatesBefore + 1)
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let issue = try #require(await boards.writing.liveIssues.first { $0.id.rawValue == refusal.issueID })
        #expect(issue.workflowState == (try scope.id(for: .todo)))
        #expect(!issue.labels.contains(try #require(boards.ids["unanswered"])))
    }

    @Test("A repeat halt posts no second createIssue and no updateIssue, only one more comment")
    func repeatHaltIsQuiet() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let (night1, run1) = try stopContext(journal, night: "2026-09-15", boards: boards)
        _ = try await AuthoringHalt.record(feature: try name("FEAT-H"), cause: seam, context: night1)
        let (night2, _) = try stopContext(journal, night: "2026-09-16", boards: boards, previous: run1)
        _ = try await AuthoringHalt.record(feature: try name("FEAT-H"), cause: seam, context: night2)

        #expect(await boards.writing.liveIssues.count == 1)
        #expect(await boards.writing.updateCalls == 0)
        let commentCount = await boards.writing.comments.count
        #expect(commentCount == 2)
        #expect(try journal.authoringHalts(feature: try name("FEAT-H")).count == 1)
    }

    @Test("A Feature that halts and is later refused still has one Feature Issue")
    func haltThenRefusalSharesTheIssue() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let (night1, run1) = try stopContext(journal, night: "2026-09-15", boards: boards)
        _ = try await AuthoringHalt.record(feature: try name("FEAT-1"), cause: seam, context: night1)
        let (night2, _) = try stopContext(journal, night: "2026-09-16", boards: boards, previous: run1)
        let outcome = try await RefusalRecording.record(feature: try name("FEAT-1"), finding: finding, context: night2)

        #expect(outcome == .refused)
        #expect(await boards.writing.liveIssues.count == 1)
        #expect(await boards.writing.createIssueCalls == 1)
        #expect(try journal.consecutiveRefusals(feature: try name("FEAT-1")) == 1)
        #expect(try journal.authoringHalts(feature: try name("FEAT-1")).count == 1)
    }

    @Test("An already-expired halt or Refusal writes nothing to the board")
    func expiredStopsWriteNothing() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let (night1, run1) = try stopContext(journal, night: "2026-09-15", boards: boards)
        _ = try await AuthoringHalt.record(feature: try name("FEAT-H"), cause: seam, context: night1)
        _ = try await RefusalRecording.record(feature: try name("FEAT-R"), finding: finding, context: night1)
        let (night2, run2) = try stopContext(journal, night: "2026-09-16", boards: boards, previous: run1)
        try await UnansweredPositionClock.run(context: night2, unansweredNightsMax: 0)
        let comments = await boards.writing.comments.count
        let creates = await boards.writing.createIssueCalls

        let (night3, _) = try stopContext(journal, night: "2026-09-17", boards: boards, previous: run2)
        _ = try await AuthoringHalt.record(feature: try name("FEAT-H"), cause: seam, context: night3)
        _ = try await RefusalRecording.record(feature: try name("FEAT-R"), finding: finding, context: night3)

        #expect(await boards.writing.comments.count == comments)
        #expect(await boards.writing.createIssueCalls == creates)
    }

    @Test("Every halt cause's comment and Night Card line avoid the Refusal vocabulary and name the repository")
    func haltVocabulary() async throws {
        let contract = UnreadableContract(cardTitle: "Card", repository: "web", paths: ["a.swift"], reason: "missing")
        let causes: [(AuthoringHaltCause, String)] = [
            (seam, "shared endpoint"), (.repositoriesUndetermined, "repositories"),
            (.contractOutsideProject(repository: "web"), "web"), (.contractUnreadable(contracts: [contract]), "web")
        ]
        for (cause, concerned) in causes {
            let fixture = try OutboxJournalFixture()
            let journal = try fixture.open()
            let boards = try await makeBuildActBoards()
            let (context, _) = try stopContext(journal, night: "2026-09-15", boards: boards)
            _ = try await AuthoringHalt.record(feature: try name("FEAT-1"), cause: cause, context: context)

            let comment = try #require(await boards.writing.comments.first).body
            let event = try #require(try journal.events(ofType: .featureAuthoringHalted).first).event
            let line = try #require(NightCardMaintenance.authoringLine(for: event))
            for text in [comment, line, cause.description] {
                #expect(!text.lowercased().contains("refus"))
                #expect(text.contains(concerned))
            }
        }
    }

    @Test("A Refusal's comment and Night Card line name its clauses and re-selection depth")
    func refusalVocabulary() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let (context, _) = try stopContext(journal, night: "2026-09-15", boards: boards)
        _ = try await RefusalRecording.record(feature: try name("FEAT-1"), finding: finding, context: context)

        let comment = try #require(await boards.writing.comments.first).body
        let event = try #require(try journal.events(ofType: .refusalOpened).first).event
        let line = try #require(NightCardMaintenance.authoringLine(for: event))
        for text in [comment, line] {
            #expect(text.contains("Ghost clause"))
            #expect(text.contains("2"))
        }
        #expect(line.contains("depth"))
        #expect(try journal.events(ofType: .featureAuthoringHalted).isEmpty)
    }
}
