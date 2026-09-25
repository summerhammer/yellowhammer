import Domain
import Foundation
import Testing

// The reading fake linked to the writing fake: the Engine's own board writes land over a scripted
// Operator gesture before the Delta Read sees it, as they do on Linear (issue #162, item 3). Unlinked, the
// fake replays the gesture regardless — which is how a repost erasing a Cancel once passed every unit test.

@Suite("FakeReadingBoard read-through")
struct FakeReadingBoardReadThroughTests {
    @Test("An Engine state write after linking overlays the scripted Operator gesture")
    func engineWriteOverlaysScriptedGesture() async throws {
        let boards = try await makeBoards()
        let issue = await boards.writing.seed(issue: "WEB-1", description: nil)
        let todo = try #require(
            try await boards.provisioning.workflowStates(team: teamID).first { $0.name == "Todo" }
        )
        let reading = FakeReadingBoard([page(objects: [object("WEB-1", state: stateCanceledByCategory)])])
        try await reading.readThrough(boards)

        _ = try await boards.writing.updateIssue(issue, BoardIssueChange(workflowState: todo.id))
        let delta = try await reading.deltaRead(since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50)

        #expect(delta.updatedObjects.map(\.workflowState) == [todo])
        #expect(await boards.writing.writes(to: issue) == [.update(BoardIssueChange(workflowState: todo.id))])
    }

    @Test("A write before linking is part of what the script stands for, and does not overlay it")
    func writeBeforeLinkingDoesNotOverlay() async throws {
        let boards = try await makeBoards()
        let issue = await boards.writing.seed(issue: "WEB-1", description: nil)
        _ = try await boards.writing.updateIssue(issue, BoardIssueChange(description: "authored"))
        let reading = FakeReadingBoard([
            page(objects: [object("WEB-1", state: stateCanceledByCategory, description: "edited by hand")])
        ])
        try await reading.readThrough(boards)

        let delta = try await reading.deltaRead(since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50)

        #expect(delta.updatedObjects.map(\.workflowState) == [stateCanceledByCategory])
        #expect(delta.updatedObjects.map(\.description) == ["edited by hand"])
    }

    @Test("An Engine archive after linking reads the scripted object as archived")
    func engineArchiveOverlays() async throws {
        let boards = try await makeBoards()
        let issue = await boards.writing.seed(issue: "WEB-1", description: nil)
        let reading = FakeReadingBoard([page(objects: [object("WEB-1", state: stateTodo)])])
        try await reading.readThrough(boards)

        try await boards.writing.archiveIssue(issue)
        let delta = try await reading.deltaRead(since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50)

        #expect(delta.updatedObjects.first?.archivedAt != nil)
    }
}
