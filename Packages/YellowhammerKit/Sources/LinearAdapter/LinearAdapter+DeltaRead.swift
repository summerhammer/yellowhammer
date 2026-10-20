import Domain
import Foundation

extension LinearAdapter {
    /// The Delta Read: board objects updated and comments created at or after each root's `since`, in this
    /// Project's Linear project, from **one** request. A skipped root is left out of the document
    /// (`@include(if: false)`), so a root that is already exhausted is never requested again and an
    /// unrequested connection adds nothing to the query's complexity. Both boundaries are inclusive
    /// (`gte`): the caller deduplicates the overlap, so an item stamped exactly at the last read's boundary
    /// is read twice rather than lost.
    public func deltaRead(
        objects: BoardRootRead, comments: BoardRootRead, pageSize: Int
    ) async throws(BoardError) -> BoardDelta {
        var variables: [String: any Sendable] = [
            "projectId": linearProjectID,
            "first": pageSize,
            "includeIssues": false,
            "includeComments": false,
            "issueFilter": buildIssueFilter(since: nil),
            "commentFilter": buildCommentFilter(since: nil)
        ]
        if case .page(let since, let after) = objects {
            variables["includeIssues"] = true
            variables["issueFilter"] = buildIssueFilter(since: since)
            if let after {
                variables["issuesAfter"] = after.rawValue
            }
        }
        if case .page(let since, let after) = comments {
            variables["includeComments"] = true
            variables["commentFilter"] = buildCommentFilter(since: since)
            if let after {
                variables["commentsAfter"] = after.rawValue
            }
        }

        let payload: LinearDeltaPayload = try await perform(LinearGraphQL.deltaReadQuery, variables: variables)

        let updatedObjects = (payload.updatedIssues?.nodes ?? []).map(Self.boardObject)
        let newComments = (payload.newComments?.nodes ?? []).map { comment in
            mapBoardComment(comment, viewerID: payload.viewer.id)
        }

        let nextObjectCursor = payload.updatedIssues.flatMap { issues in
            issues.pageInfo.hasNextPage ? issues.pageInfo.endCursor.map(BoardCursor.init) : nil
        }
        let nextCommentCursor = payload.newComments.flatMap { comments in
            comments.pageInfo.hasNextPage ? comments.pageInfo.endCursor.map(BoardCursor.init) : nil
        }

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
            filter["updatedAt"] = ["gte": LinearGraphQL.timestampString(since)]
        }
        return filter
    }

    private func buildCommentFilter(since: Date?) -> [String: any Sendable] {
        let scope: [String: any Sendable] = ["project": ["id": ["eq": linearProjectID]]] // glossary:ignore GL001
        var filter: [String: any Sendable] = ["issue": scope]
        if let since {
            filter["createdAt"] = ["gte": LinearGraphQL.timestampString(since)]
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
                name: comment.issue.state.name,
                category: LinearAdapter.category(of: comment.issue.state.type)
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
