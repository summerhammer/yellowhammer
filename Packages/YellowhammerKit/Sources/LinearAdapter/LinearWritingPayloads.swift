import Foundation

/// Decoded payloads for writing queries.

struct LinearIssueDescriptionPayload: Decodable {
    let issue: LinearIssueDescriptionData?
}

struct LinearIssueDescriptionData: Decodable {
    let id: String
    let description: String?
    let updatedAt: Date
    /// Nil when the issue belongs to no Linear project, which is outside every Project's scope.
    let project: LinearProjectReference?
}

struct LinearProjectReference: Decodable {
    let id: String
}

struct LinearCreateIssuePayload: Decodable {
    let issueCreate: LinearCreateIssueData?
}

struct LinearCreateIssueData: Decodable {
    let success: Bool
    let issue: LinearCreatedIssue?
}

struct LinearCreatedIssue: Decodable {
    let id: String
}

struct LinearCreateCommentPayload: Decodable {
    let commentCreate: LinearCreateCommentData?
}

struct LinearCreateCommentData: Decodable {
    let success: Bool
    let comment: LinearCreatedComment?
}

struct LinearCreatedComment: Decodable {
    let id: String
}

struct LinearAttachLinkPayload: Decodable {
    let attachmentLinkURL: LinearAttachLinkData?
}

struct LinearAttachLinkData: Decodable {
    let success: Bool
    let attachment: LinearCreatedAttachment?
}

struct LinearCreatedAttachment: Decodable {
    let id: String
}

struct LinearUpdateIssuePayload: Decodable {
    let issueUpdate: LinearUpdateIssueData?
}

struct LinearUpdateIssueData: Decodable {
    let success: Bool
    let issue: LinearUpdatedIssue?
}

struct LinearUpdatedIssue: Decodable {
    let id: String
    let description: String?
    let updatedAt: Date
}

struct LinearArchiveIssuePayload: Decodable {
    let issueArchive: LinearArchiveIssueData?
}

struct LinearArchiveIssueData: Decodable {
    let success: Bool
}
