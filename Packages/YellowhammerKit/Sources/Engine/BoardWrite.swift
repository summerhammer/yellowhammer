import CryptoKit
import Domain
import Foundation

/// One board write in Yellowhammer's vocabulary: what the Outbox accepts, persists as the entry's
/// payload, and lands on the board through the Board Port. Every write there is — issue creation,
/// Managed Block rewrites, comments, labels, workflow state, assignment, attachments, `parentId`
/// changes, archiving — is one of these.
public enum BoardWrite: Codable, Equatable, Sendable {
    /// Creates a Card, a Feature Issue or a Night Card. `parentKey` names an earlier accepted
    /// ``createIssue(_:parentKey:)`` whose created id becomes this issue's parent, so a Card can be
    /// nested under a Feature Issue that does not exist yet when both are accepted together.
    case createIssue(BoardIssueDraft, parentKey: String?)
    case createComment(issue: BoardObjectID, body: String)
    case attachLink(issue: BoardObjectID, url: String, title: String)
    /// Replaces the text between the Managed Block delimiters with `rendered`, after a pre-flight
    /// read of the description as it is at that instant. The only way a description is written.
    case rewriteManagedBlock(issue: BoardObjectID, rendered: String)
    /// Replaces matching report lines at delivery time, preserving the rest of the current block.
    case updateManagedBlockLine(issue: BoardObjectID, prefix: String, line: String)
    /// Workflow state, labels, assignment, `parentId` and title. Never a description: the Outbox
    /// refuses a change that carries one. `undo` is what a rollback applies if a group this write
    /// belongs to cannot complete — an adopted Card's previous parent, for instance.
    case updateIssue(issue: BoardObjectID, change: BoardIssueChange, undo: BoardIssueChange?)
    case archiveIssue(issue: BoardObjectID)
    /// Adopts an existing Card into a Feature Issue accepted in the same group (roadmap P9.4): at
    /// delivery `parentKey` resolves to that Feature Issue's created id and the Card is re-parented to
    /// it. `undo` is what a rollback applies — the Card's previous parent. Additive: it never changes how
    /// any earlier case encodes or decodes.
    case adoptIssue(issue: BoardObjectID, parentKey: String, undo: BoardIssueChange?)

    /// The operation as the Journal names it.
    public var operation: String {
        switch self {
        case .createIssue: "issueCreate"
        case .createComment: "commentCreate"
        case .attachLink: "attachmentCreate"
        case .rewriteManagedBlock: "descriptionRewrite"
        case .updateManagedBlockLine: "descriptionRewrite"
        case .updateIssue: "issueUpdate"
        case .archiveIssue: "issueArchive"
        case .adoptIssue: "issueUpdate"
        }
    }

    /// The issue the write addresses, when it addresses one that exists.
    public var issueID: BoardObjectID? {
        switch self {
        case .createIssue:
            nil
        case .createComment(let issue, _), .attachLink(let issue, _, _), .rewriteManagedBlock(let issue, _),
             .updateIssue(let issue, _, _), .archiveIssue(let issue), .adoptIssue(let issue, _, _),
             .updateManagedBlockLine(let issue, _, _):
            issue
        }
    }

    /// Whether the board applies this write under a client-supplied id.
    var isCreate: Bool {
        switch self {
        case .createIssue, .createComment, .attachLink: true
        case .rewriteManagedBlock, .updateManagedBlockLine, .updateIssue, .archiveIssue, .adoptIssue: false
        }
    }
}

/// What the Engine hands the Outbox: a write, the key that makes its client id deterministic, and
/// the Card whose Lease guards it.
public struct OutboxWrite: Equatable, Sendable {
    /// Stable and unique for the logical write within the Project — the same key on a retried or
    /// resumed Act names the same write, which is what makes replay safe. Something like
    /// `card:<cycle>:<repository>:<order>:create` or `comment:<issue>:<attempt>:crash`.
    public var key: String
    public var write: BoardWrite
    /// The Journal's `card.id` of the Card this write is about, so its Lease is revalidated before the
    /// write; nil for a write with no Card behind it (a Feature Issue's, a Night Card's).
    public var cardID: Int64?

    public init(key: String, write: BoardWrite, cardID: Int64? = nil) {
        self.key = key
        self.write = write
        self.cardID = cardID
    }
}

/// Deterministic client ids: the same Project, salt and key always yield the same UUID, so a write
/// replayed after a crash carries the id the board already knows. Two Projects never share one, because
/// the Project id is in the digest.
///
/// `salt` is the Journal's `outboxSalt` — empty for a Journal that already held Outbox entries when
/// `v29-outbox-salt` ran, otherwise fixed for that Journal's life. It exists so a reset Project (Journal
/// deleted, its Linear issues archived) gets a fresh Journal whose ids never recompute to the id of an
/// issue the previous Journal already created and that is now archived: without the salt, replaying the
/// same key after a reset would resolve to the archived issue and the write would land invisibly on it.
public enum OutboxClientID {
    public static func make(projectID: ProjectID, salt: String, key: String) -> UUID {
        let input = salt.isEmpty
            ? "yellowhammer-outbox|\(projectID.rawValue)|\(key)"
            : "yellowhammer-outbox|\(projectID.rawValue)|\(salt)|\(key)"
        let digest = SHA256.hash(data: Data(input.utf8))
        var bytes = Array(digest.prefix(16))
        // Stamped version 4 and the RFC 4122 variant, although the bytes are a digest, not random: Linear
        // accepts a client-supplied id only in v4 form and refuses a v5 one ("id must be a UUID").
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
