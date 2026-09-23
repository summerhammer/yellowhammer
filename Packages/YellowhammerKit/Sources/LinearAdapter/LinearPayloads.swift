import Foundation

/// The decoded shapes of Yellowhammer's two Linear queries.
struct LinearViewerPayload: Decodable {
    let viewer: Viewer

    struct Viewer: Decodable {
        let id: String
        let name: String
    }
}

struct LinearIssuesPayload: Decodable {
    let issues: Issues

    struct Issues: Decodable {
        let pageInfo: PageInfo
        let nodes: [Issue]
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct Issue: Decodable {
        let id: String
        let identifier: String
        let title: String
        let description: String?
        let url: String
        let createdAt: Date
        let updatedAt: Date
        let archivedAt: Date?
        let trashed: Bool?
        let state: Node
        let labels: Labels
        let parent: Reference?
        let assignee: Reference?
    }

    struct Node: Decodable {
        let id: String
        let name: String
    }

    struct Labels: Decodable {
        let nodes: [Label]
    }

    struct Label: Decodable {
        let name: String
    }

    struct Reference: Decodable {
        let id: String
    }
}

/// A single issue read (settle gesture, roadmap P10.9); `issue` is nil when Linear has no issue with
/// that id, or it is outside this identity's reach.
struct LinearIssuePayload: Decodable {
    let issue: LinearIssuesPayload.Issue?
}

/// Whether a workspace member is active (roadmap P11.1); `user` is nil only when the query's response
/// carried no GraphQL error and no user, which Linear does not do in practice — the not-found case
/// arrives as a GraphQL error instead, translated to ``BoardError/scopeNotFound(_:)``.
struct LinearUserPayload: Decodable {
    let user: User?

    struct User: Decodable {
        let id: String
        let active: Bool
    }
}

struct LinearDeltaPayload: Decodable {
    let viewer: DeltaViewerPayload
    let updatedIssues: LinearIssuesPayload.Issues
    let newComments: DeltaComments

    struct DeltaViewerPayload: Decodable {
        let id: String
        let name: String
    }

    struct DeltaComments: Decodable {
        let pageInfo: DeltaPageInfo
        let nodes: [DeltaComment]
    }

    struct DeltaPageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct DeltaComment: Decodable {
        let id: String
        let createdAt: Date
        let body: String
        let parent: DeltaCommentReference?
        let user: DeltaCommentUser?
        let botActor: DeltaCommentBot?
        let issue: DeltaCommentIssue
    }

    struct DeltaCommentReference: Decodable {
        let id: String
    }

    struct DeltaCommentUser: Decodable {
        let id: String
        let name: String
        let isMe: Bool
    }

    struct DeltaCommentBot: Decodable {
        let id: String?
        let name: String?
    }

    struct DeltaCommentIssue: Decodable {
        let id: String
        let identifier: String
        let state: DeltaCommentState
    }

    struct DeltaCommentState: Decodable {
        let id: String
        let name: String
    }
}
