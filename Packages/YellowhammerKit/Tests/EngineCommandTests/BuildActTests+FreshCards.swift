import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Testing

// The build Act's board repost and a freshly authored Card, split out of BuildActTests.swift to keep
// that file under the file length limit. The authoring group created the Card on the board in Todo, so
// the repost has no write of its own to post for it: an Operator's gesture on the board before the first
// build Act stands, for the Delta Read to read (found by the P15.3 rehearsal suite's scenario 11).

extension BuildActTests {
    @Test("A freshly authored Card cancelled on the board before the first build Act is read Cancelled, not reposted")
    func freshCardCancelledOnTheBoardIsNotReposted() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordFeatureBranch(featureID: featureID, branch: buildActBranch)
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        // Freshly authored: Todo at state_version 0, and no state write of its own ever posted.
        let webCard = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "WEB-1", repository: "web", state: .todo
        )

        let boards = try await makeBuildActBoards()
        let webIssue = await boards.writing.seed(issue: "WEB-1", description: nil)
        // The Operator moved it to the team's own cancelled state, as a real Linear team names it.
        let reading = FakeReadingBoard([page(objects: [object("WEB-1", state: stateCanceledByCategory)])])
        let board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)

        let recorder = RecordingCardRunner()
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, board: board, work: BuildAct(cardRunner: recorder).work
        )

        try await invocation.run()

        let events = try journal.events()
        guard case .boardStateReposted(let posted) = try #require(
            events.first { $0.type == .boardStateReposted }?.event
        ) else {
            Issue.record("expected boardStateReposted")
            return
        }
        #expect(posted == 0)
        #expect(await boards.writing.issue(webIssue)?.workflowState == nil)

        #expect(events.filter { $0.type == .cardCancelled }.count == 1)
        #expect(try journal.card(id: webCard).state == .cancelled)
        #expect(recorder.seen.isEmpty)
    }
}
