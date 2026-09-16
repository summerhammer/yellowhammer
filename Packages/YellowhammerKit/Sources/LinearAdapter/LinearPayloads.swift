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
