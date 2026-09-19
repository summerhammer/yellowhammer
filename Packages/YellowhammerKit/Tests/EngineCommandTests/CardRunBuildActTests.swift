import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P8.4 through the build Act: a fixture Feature with two Repo Lanes, each Card run from Ready to
// Done by the Card run over rehearsal result fixtures, on the Worktree its own lane holds.

@Suite("Card run in the build Act")
struct CardRunBuildActTests {
    @Test("A rehearsal build Act runs both Repo Lanes' Cards from Ready to Done, one Worktree per lane")
    func rehearsalBuildActRunsTwoLanesToDone() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let git = GitRunner()
        let worktrees = fixture.directory.appending(component: "worktrees", directoryHint: .isDirectory)
        for repository in ["backend", "mobile"] {
            try initReconcilerGitRepo(at: worktrees.appending(component: repository), git: git)
        }
        let world = try await makeCardRunWorld(
            journal: journal, cards: [("BACK-1", "backend"), ("BACK-2", "backend"), ("MOB-1", "mobile")],
            worktreePath: { worktrees.appending(component: $0).path(percentEncoded: false) }
        )
        let rehearsal = RehearsalDispatch()
        let log = CallLog()
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: rehearsal, check: RecordingCheck(log: log),
            checks: ["backend": .none, "mobile": .none], reviewRoundsMax: 2, attemptsPerCard: 3
        )
        let board = try #require(world.context.act.board)
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: world.runID, board: board, workspace: ReconcilerFakeWorkspace(),
            work: BuildAct(cardRunner: run).work
        )

        try await invocation.run()

        for issueID in ["BACK-1", "BACK-2", "MOB-1"] {
            #expect(try world.card(issueID).state == .done)
            let attempt = try #require(try world.attempts(issueID).first)
            #expect(attempt.result == "success")
        }
        // Each Card ran all three passes and the Check, in that order, in its own lane's Worktree.
        #expect(rehearsal.answered.count == 9)
        #expect(log.all == Array(repeating: "check", count: 3))
        for request in rehearsal.answered {
            let repository = try #require(request.issueID.hasPrefix("BACK") ? "backend" : "mobile")
            #expect(request.worktreePath == worktrees.appending(component: repository).path(percentEncoded: false))
        }
        // Within the backend lane, BACK-1 finished before BACK-2 began.
        let backend = rehearsal.answered.filter { $0.issueID.hasPrefix("BACK") }.map(\.issueID)
        #expect(backend == ["BACK-1", "BACK-1", "BACK-1", "BACK-2", "BACK-2", "BACK-2"])
        #expect(try journal.events(ofType: .repoLaneEnded).count == 2)
        #expect(try journal.currentActLease() == nil)
    }
}
