import Domain
import Foundation

extension LinearAdapter: BoardWriting {
    public func issueDescription(_ issue: BoardObjectID) async throws(BoardError) -> BoardDescriptionSnapshot {
        let payload: LinearIssueDescriptionPayload = try await perform(
            LinearGraphQL.issueDescriptionQuery, variables: ["id": issue.rawValue]
        )
        guard let issueData = payload.issue else {
            throw .scopeNotFound("the issue was not found")
        }
        guard issueData.project?.id == linearProjectID else {
            throw .scopeNotFound("the issue is outside this Linear project")
        }
        return BoardDescriptionSnapshot(
            id: BoardObjectID(rawValue: issueData.id),
            description: issueData.description,
            updatedAt: issueData.updatedAt
        )
    }

    public func createIssue(_ draft: BoardIssueDraft, clientID: UUID) async throws(BoardError) -> BoardCreateReceipt {
        let idString = clientID.uuidString.lowercased()
        var input: [String: any Sendable] = [
            "id": idString,
            "teamId": draft.team.rawValue,
            "projectId": linearProjectID,
            "title": draft.title
        ]
        if let description = draft.description {
            input["description"] = description
        }
        if let parent = draft.parent {
            input["parentId"] = parent.rawValue
        }
        if !draft.labels.isEmpty {
            input["labelIds"] = draft.labels.map(\.rawValue)
        }
        if let workflowState = draft.workflowState {
            input["stateId"] = workflowState.rawValue
        }
        if let assignee = draft.assignee {
            input["assigneeId"] = assignee.rawValue
        }

        let outcome: LinearOutcome<LinearCreateIssuePayload> = try await send(
            LinearGraphQL.createIssueQuery, variables: ["input": input]
        )
        switch outcome {
        case .payload(let payload):
            guard let createData = payload.issueCreate else {
                throw .refused("Linear issue creation returned no data")
            }
            guard createData.success else {
                throw .refused("Linear refused to create the issue")
            }
            guard let createdIssue = createData.issue else {
                throw .refused("Linear created the issue but returned no issue data")
            }
            return .created(BoardObjectID(rawValue: createdIssue.id))
        case .insertConflict:
            return .alreadyApplied(BoardObjectID(rawValue: idString))
        }
    }

    public func createComment(
        on issue: BoardObjectID, body: String, clientID: UUID
    ) async throws(BoardError) -> BoardCreateReceipt {
        let idString = clientID.uuidString.lowercased()
        let input: [String: any Sendable] = [
            "id": idString,
            "issueId": issue.rawValue,
            "body": body
        ]

        let outcome: LinearOutcome<LinearCreateCommentPayload> = try await send(
            LinearGraphQL.createCommentQuery, variables: ["input": input]
        )
        switch outcome {
        case .payload(let payload):
            guard let createData = payload.commentCreate else {
                throw .refused("Linear comment creation returned no data")
            }
            guard createData.success else {
                throw .refused("Linear refused to create the comment")
            }
            guard let createdComment = createData.comment else {
                throw .refused("Linear created the comment but returned no comment data")
            }
            return .created(BoardObjectID(rawValue: createdComment.id))
        case .insertConflict:
            return .alreadyApplied(BoardObjectID(rawValue: idString))
        }
    }

    public func attachLink(
        to issue: BoardObjectID, url: String, title: String, clientID: UUID
    ) async throws(BoardError) -> BoardCreateReceipt {
        let idString = clientID.uuidString.lowercased()
        let variables: [String: any Sendable] = [
            "id": idString,
            "issueId": issue.rawValue,
            "url": url,
            "title": title
        ]

        let outcome: LinearOutcome<LinearAttachLinkPayload> = try await send(
            LinearGraphQL.attachLinkQuery, variables: variables
        )
        switch outcome {
        case .payload(let payload):
            guard let attachData = payload.attachmentLinkURL else {
                throw .refused("Linear attachment creation returned no data")
            }
            guard attachData.success else {
                throw .refused("Linear refused to attach the link")
            }
            guard let createdAttachment = attachData.attachment else {
                throw .refused("Linear created the attachment but returned no attachment data")
            }
            return .created(BoardObjectID(rawValue: createdAttachment.id))
        case .insertConflict:
            return .alreadyApplied(BoardObjectID(rawValue: idString))
        }
    }

    public func updateIssue(_ issue: BoardObjectID, _ change: BoardIssueChange) async throws(
        BoardError
    ) -> BoardDescriptionSnapshot {
        guard !change.isEmpty else {
            throw .refused("nothing to update")
        }

        let input = Self.updateInput(for: change)
        let payload: LinearUpdateIssuePayload = try await perform(
            LinearGraphQL.updateIssueQuery, variables: ["id": issue.rawValue, "input": input]
        )
        guard let updateData = payload.issueUpdate else {
            throw .refused("Linear issue update returned no data")
        }
        guard updateData.success else {
            throw .refused("Linear refused to update the issue")
        }
        guard let updatedIssue = updateData.issue else {
            throw .refused("Linear updated the issue but returned no issue data")
        }
        return BoardDescriptionSnapshot(
            id: BoardObjectID(rawValue: updatedIssue.id),
            description: updatedIssue.description,
            updatedAt: updatedIssue.updatedAt
        )
    }

    /// Builds the input dictionary for a Linear issue update mutation, including only the given fields.
    private static func updateInput(for change: BoardIssueChange) -> [String: any Sendable] {
        var input: [String: any Sendable] = [:]
        if let title = change.title {
            input["title"] = title
        }
        if let description = change.description {
            input["description"] = description
        }
        if let workflowState = change.workflowState {
            input["stateId"] = workflowState.rawValue
        }
        if !change.addLabels.isEmpty {
            input["addedLabelIds"] = change.addLabels.map(\.rawValue)
        }
        if !change.removeLabels.isEmpty {
            input["removedLabelIds"] = change.removeLabels.map(\.rawValue)
        }
        if let assignee = change.assignee {
            input["assigneeId"] = referenceValue(assignee)
        }
        if let parent = change.parent {
            input["parentId"] = referenceValue(parent)
        }
        return input
    }

    /// Converts a reference change to its JSON value: the id string for `.set`, or null for `.clear`.
    private static func referenceValue(_ ref: BoardReferenceChange) -> any Sendable {
        switch ref {
        case .set(let id):
            id.rawValue
        case .clear:
            NSNull()
        }
    }

    public func archiveIssue(_ issue: BoardObjectID) async throws(BoardError) {
        // The scope check first: an issue outside this Project's Linear project is never archived.
        _ = try await issueDescription(issue)

        let payload: LinearArchiveIssuePayload = try await perform(
            LinearGraphQL.archiveIssueQuery, variables: ["id": issue.rawValue]
        )
        guard let archiveData = payload.issueArchive else {
            throw .refused("Linear issue archive returned no data")
        }
        guard archiveData.success else {
            throw .refused("Linear refused to archive the issue")
        }
    }
}
