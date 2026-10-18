import Foundation
import Journal

/// An Authoring Halt or Refusal awaiting an Operator turn in Linear, including before a Cycle exists.
public struct AuthoringDecision: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case halt = "Authoring halted"
        case refusal = "Authoring refused"
    }

    public let id: String
    public let title: String
    public let kind: Kind
    public let reason: String
    public let link: LinearIssueLink?
    /// The Night that first recorded this still-open decision.
    public let openedNightID: Int64

    public init(
        id: String, title: String, kind: Kind, reason: String, link: LinearIssueLink? = nil,
        openedNightID: Int64
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.reason = reason
        self.link = link
        self.openedNightID = openedNightID
    }
}

extension PulseSnapshot {
    static func authoringDecisions(_ journal: JournalStore) throws -> [AuthoringDecision] {
        let halts = try journal.openAuthoringHalts().map { record in
            AuthoringDecision(
                id: "halt-\(record.id)", title: record.featureName, kind: .halt, reason: record.content,
                link: try authoringIssueLink(record.issueID, journal: journal), openedNightID: record.openedNightID
            )
        }
        let refusals = try journal.openRefusals().map { record in
            AuthoringDecision(
                id: "refusal-\(record.id)", title: record.featureName, kind: .refusal, reason: record.content,
                link: try authoringIssueLink(record.issueID, journal: journal), openedNightID: record.openedNightID
            )
        }
        return halts + refusals
    }

    private static func authoringIssueLink(_ issueID: String?, journal: JournalStore) throws -> LinearIssueLink? {
        guard let issueID else { return nil }
        if let feature = try journal.feature(issueID: issueID),
           let recorded = LinearIssueLink.link(
            key: feature.issueIDForDisplay ?? feature.issueKey, url: feature.issueURL
           ) {
            return recorded
        }
        // Authoring stops predate a Feature row. Existing Journals retain only Linear's issue UUID.
        guard UUID(uuidString: issueID) != nil,
              let url = URL(string: "https://linear.app/issue/" + issueID) else { return nil }
        return LinearIssueLink(identifier: issueID, url: url)
    }
}
