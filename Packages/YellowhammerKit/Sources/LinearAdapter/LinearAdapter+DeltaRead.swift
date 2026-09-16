import Domain
import Foundation

extension LinearAdapter {
    /// The Delta Read: board objects updated and comments created after `since`, in this Project's
    /// Linear project, from **one** request.
    public func deltaRead(
        since: Date?, objectsAfter: BoardCursor?, commentsAfter: BoardCursor?, pageSize: Int
    ) async throws(BoardError) -> BoardDelta {
        let issueFilter = buildIssueFilter(since: since)
        let commentFilter = buildCommentFilter(since: since)

        var variables: [String: any Sendable] = [
            "projectId": linearProjectID,
            "issueFilter": issueFilter,
            "commentFilter": commentFilter,
            "first": pageSize
        ]
        if let objectsAfter {
            variables["issuesAfter"] = objectsAfter.rawValue
        }
        if let commentsAfter {
            variables["commentsAfter"] = commentsAfter.rawValue
        }

        let payload: LinearDeltaPayload = try await perform(LinearGraphQL.deltaReadQuery, variables: variables)

        let updatedObjects = payload.updatedIssues.nodes.map(Self.boardObject)
        let newComments = payload.newComments.nodes.map { comment in
            mapBoardComment(comment, viewerID: payload.viewer.id)
        }

        let nextObjectCursor = payload.updatedIssues.pageInfo.hasNextPage
            ? payload.updatedIssues.pageInfo.endCursor.map(BoardCursor.init)
            : nil
        let nextCommentCursor = payload.newComments.pageInfo.hasNextPage
            ? payload.newComments.pageInfo.endCursor.map(BoardCursor.init)
            : nil

        return BoardDelta(
            identity: BoardIdentity(id: BoardObjectID(rawValue: payload.viewer.id), name: payload.viewer.name),
            updatedObjects: updatedObjects,
            newComments: newComments,
            nextObjectCursor: nextObjectCursor,
            nextCommentCursor: nextCommentCursor
        )
    }

    private func buildIssueFilter(since: Date?) -> [String: any Sendable] {
        var filter: [String: any Sendable] = ["project": ["id": ["eq": linearProjectID]]] // glossary:ignore GL001
        if let since {
            filter["updatedAt"] = ["gt": LinearGraphQL.timestampString(since)]
        }
        return filter
    }

    private func buildCommentFilter(since: Date?) -> [String: any Sendable] {
        let scope: [String: any Sendable] = ["project": ["id": ["eq": linearProjectID]]] // glossary:ignore GL001
        var filter: [String: any Sendable] = ["issue": scope]
        if let since {
            filter["createdAt"] = ["gt": LinearGraphQL.timestampString(since)]
        }
        return filter
    }

    private func mapBoardComment(
        _ comment: LinearDeltaPayload.DeltaComment,
        viewerID: String
    ) -> BoardComment {
        let author = mapCommentAuthor(comment, viewerID: viewerID)
        return BoardComment(
            id: BoardObjectID(rawValue: comment.id),
            issue: BoardObjectID(rawValue: comment.issue.id),
            issueKey: comment.issue.identifier,
            issueWorkflowState: BoardWorkflowState(
                id: BoardObjectID(rawValue: comment.issue.state.id),
                name: comment.issue.state.name
            ),
            body: comment.body,
            parent: comment.parent.map { BoardObjectID(rawValue: $0.id) },
            author: author,
            createdAt: comment.createdAt
        )
    }

    private func mapCommentAuthor(
        _ comment: LinearDeltaPayload.DeltaComment,
        viewerID: String
    ) -> BoardCommentAuthor {
        if let user = comment.user {
            return BoardCommentAuthor(
                id: BoardObjectID(rawValue: user.id),
                name: user.name,
                isYellowhammer: user.isMe || user.id == viewerID
            )
        } else if let botActor = comment.botActor {
            return BoardCommentAuthor(
                id: botActor.id.map(BoardObjectID.init),
                name: botActor.name ?? "integration",
                isYellowhammer: botActor.id == viewerID
            )
        } else {
            return BoardCommentAuthor(id: nil, name: "unknown", isYellowhammer: false)
        }
    }
}
