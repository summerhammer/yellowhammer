import Domain
import Foundation

/// An in-memory board for the writing half of the Port. It behaves the way Linear does where the
/// Outbox depends on it: a create under a client id it has seen is "already applied", and an issue's
/// description is whatever was last written — by the Outbox or by the "Operator" through `edit`.
actor FakeWritingBoard: BoardWriting {
    struct Issue: Equatable, Sendable {
        var id: BoardObjectID
        var title: String
        var description: String?
        var parent: BoardObjectID?
        var labels: Set<BoardObjectID>
        var workflowState: BoardObjectID?
        var assignee: BoardObjectID?
        var archived = false
        var updatedAt: Date
    }

    struct Attachment: Equatable, Sendable {
        let id: BoardObjectID
        let issue: BoardObjectID
        let url: String
    }

    struct Comment: Equatable, Sendable {
        let id: BoardObjectID
        let issue: BoardObjectID
        let body: String
    }

    /// Scripted behaviour for one create, keyed by issue title or comment body.
    enum Script: Sendable {
        /// Refuse without applying.
        case refuse(BoardError)
        /// Apply, then lose the response: the board did the work and the caller hears `unreachable`.
        case loseResponse
    }

    /// One write the Engine made to an existing issue, in the order it reached the board.
    enum Write: Equatable, Sendable {
        case update(BoardIssueChange)
        case archive
    }

    private(set) var issues: [BoardObjectID: Issue] = [:]
    /// Every `updateIssue` and `archiveIssue` that was applied, in order — what a linked
    /// ``FakeReadingBoard`` overlays on its scripted pages, and what ``writes(to:)`` reports.
    private(set) var writeLog: [(issue: BoardObjectID, write: Write)] = []
    private(set) var comments: [Comment] = []
    private(set) var attachments: [Attachment] = []
    private var issueClientIDs: [UUID: BoardObjectID] = [:]
    private var commentClientIDs: [UUID: BoardObjectID] = [:]
    private var attachmentClientIDs: [UUID: BoardObjectID] = [:]
    private var scripts: [String: Script] = [:]
    /// Errors thrown by the next calls of any kind, in order, before anything is applied.
    private var refusals: [BoardError] = []
    /// Persistently refuses every `updateIssue` call naming this issue, until cleared — unlike
    /// ``refuseNext(_:)``, which is consumed once. For a caller that needs one specific write (a Card's
    /// state write and nothing else touching the same issue) to keep failing across many attempts,
    /// where counting exact call order would be fragile.
    private var issueRefusals: [BoardObjectID: BoardError] = [:]

    private(set) var createIssueCalls = 0
    private(set) var createCommentCalls = 0
    private(set) var descriptionReads = 0
    private(set) var updateCalls = 0
    private(set) var archiveCalls = 0

    private var archiveAfterUpdate = false
    func archiveAfterNextUpdate() { archiveAfterUpdate = true }

    private var nextID = 0
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    var liveIssues: [Issue] { issues.values.filter { !$0.archived }.sorted { $0.id.rawValue < $1.id.rawValue } }
    var archivedIssues: [Issue] { issues.values.filter(\.archived).sorted { $0.id.rawValue < $1.id.rawValue } }

    // MARK: - Scripting

    @discardableResult
    func seed(issue id: String, description: String?) -> BoardObjectID {
        let issueID = BoardObjectID(rawValue: id)
        issues[issueID] = Issue(
            id: issueID, title: id, description: description, parent: nil, labels: [], updatedAt: now
        )
        return issueID
    }

    /// The Operator puts a label on the issue by hand.
    func label(_ issue: BoardObjectID, add label: BoardObjectID) {
        issues[issue]?.labels.insert(label)
    }

    /// The Operator edits the description between the Outbox accepting a write and delivering it.
    func edit(_ issue: BoardObjectID, description: String?) {
        issues[issue]?.description = description
        issues[issue]?.updatedAt = now.addingTimeInterval(1)
    }

    func script(_ script: Script, for titleOrBody: String) {
        scripts[titleOrBody] = script
    }

    /// Clears a scripted refusal set by ``script(_:for:)`` — unlike `.loseResponse`, `.refuse` does not
    /// clear itself on its own, since a real refusal (unlike a lost response) repeats on every retry
    /// until whatever caused it is gone.
    func clearScript(for titleOrBody: String) {
        scripts[titleOrBody] = nil
    }

    func refuseNext(_ error: BoardError) {
        refusals.append(error)
    }

    /// Every `updateIssue` naming `issue` throws `error` until ``clearRefusal(issue:)``.
    func refuse(issue: BoardObjectID, with error: BoardError) {
        issueRefusals[issue] = error
    }

    func clearRefusal(issue: BoardObjectID) {
        issueRefusals[issue] = nil
    }

    func issue(_ id: BoardObjectID) -> Issue? { issues[id] }

    /// Every write applied to `issue` after the first `since` entries of the log — empty when none
    /// reached it. For a test asserting the Engine left an Operator's gesture alone.
    func writes(to issue: BoardObjectID, since: Int = 0) -> [Write] {
        writeLog.dropFirst(since).filter { $0.issue == issue }.map(\.write)
    }

    // MARK: - BoardWriting

    func issueDescription(_ issue: BoardObjectID) async throws(BoardError) -> BoardDescriptionSnapshot {
        descriptionReads += 1
        try consumeRefusal()
        guard let found = issues[issue] else { throw .scopeNotFound("no such issue") }
        return BoardDescriptionSnapshot(id: found.id, description: found.description, updatedAt: found.updatedAt)
    }

    func createIssue(_ draft: BoardIssueDraft, clientID: UUID) async throws(BoardError) -> BoardCreateReceipt {
        createIssueCalls += 1
        try consumeRefusal()
        if let existing = issueClientIDs[clientID] {
            return .alreadyApplied(existing)
        }
        if case .refuse(let error)? = scripts[draft.title] {
            throw error
        }
        let id = mint("issue")
        issues[id] = Issue(
            id: id,
            title: draft.title,
            description: draft.description,
            parent: draft.parent,
            labels: Set(draft.labels),
            workflowState: draft.workflowState,
            assignee: draft.assignee,
            updatedAt: now
        )
        issueClientIDs[clientID] = id
        if case .loseResponse? = scripts[draft.title] {
            scripts[draft.title] = nil
            throw .unreachable("the response was lost")
        }
        return .created(id)
    }

    func createComment(
        on issue: BoardObjectID, body: String, clientID: UUID
    ) async throws(BoardError) -> BoardCreateReceipt {
        createCommentCalls += 1
        try consumeRefusal()
        if let existing = commentClientIDs[clientID] {
            return .alreadyApplied(existing)
        }
        if case .refuse(let error)? = scripts[body] {
            throw error
        }
        guard issues[issue] != nil else { throw .scopeNotFound("no such issue") }
        let id = mint("comment")
        comments.append(Comment(id: id, issue: issue, body: body))
        commentClientIDs[clientID] = id
        if case .loseResponse? = scripts[body] {
            scripts[body] = nil
            throw .unreachable("the response was lost")
        }
        return .created(id)
    }

    func attachLink(
        to issue: BoardObjectID, url: String, title: String, clientID: UUID
    ) async throws(BoardError) -> BoardCreateReceipt {
        try consumeRefusal()
        if let existing = attachmentClientIDs[clientID] {
            return .alreadyApplied(existing)
        }
        guard issues[issue] != nil else { throw .scopeNotFound("no such issue") }
        let id = mint("attachment")
        attachments.append(Attachment(id: id, issue: issue, url: url))
        attachmentClientIDs[clientID] = id
        return .created(id)
    }

    func updateIssue(
        _ issue: BoardObjectID, _ change: BoardIssueChange
    ) async throws(BoardError) -> BoardDescriptionSnapshot {
        updateCalls += 1
        try consumeRefusal()
        if let error = issueRefusals[issue] { throw error }
        guard let found = issues[issue] else { throw .scopeNotFound("no such issue") }
        let updated = Self.applying(change, to: found, now: now)
        issues[issue] = updated
        if archiveAfterUpdate {
            archiveAfterUpdate = false
            issues[issue]?.archived = true
        }
        writeLog.append((issue, .update(change)))
        return BoardDescriptionSnapshot(id: issue, description: updated.description, updatedAt: updated.updatedAt)
    }

    /// The updated `Issue` `change` describes, applied field by field — split out of ``updateIssue``
    /// purely to stay under the cyclomatic-complexity limit.
    private static func applying(_ change: BoardIssueChange, to issue: Issue, now: Date) -> Issue {
        var found = issue
        if let title = change.title { found.title = title }
        if let description = change.description { found.description = description }
        if let state = change.workflowState { found.workflowState = state }
        found.labels.formUnion(change.addLabels)
        found.labels.subtract(change.removeLabels)
        switch change.assignee {
        case .set(let id)?: found.assignee = id
        case .clear?: found.assignee = nil
        case nil: break
        }
        switch change.parent {
        case .set(let id)?: found.parent = id
        case .clear?: found.parent = nil
        case nil: break
        }
        found.updatedAt = now.addingTimeInterval(2)
        return found
    }

    func archiveIssue(_ issue: BoardObjectID) async throws(BoardError) {
        archiveCalls += 1
        try consumeRefusal()
        guard issues[issue] != nil else { throw .scopeNotFound("no such issue") }
        issues[issue]?.archived = true
        writeLog.append((issue, .archive))
    }

    // MARK: - Private

    private func consumeRefusal() throws(BoardError) {
        guard !refusals.isEmpty else { return }
        throw refusals.removeFirst()
    }

    private func mint(_ kind: String) -> BoardObjectID {
        nextID += 1
        return BoardObjectID(rawValue: "\(kind)-\(nextID)")
    }
}
