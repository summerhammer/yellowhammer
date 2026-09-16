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
        let state: Node
        let labels: Labels
        let parent: Reference?
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
