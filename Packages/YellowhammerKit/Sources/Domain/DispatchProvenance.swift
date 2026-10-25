import Foundation

/// Provenance identifying what dispatch a prompt record belongs to: its family, execution context,
/// and where applicable its Night, Feature, Card, Attempt, Round and Route try.
public struct DispatchProvenance: Codable, Equatable, Sendable {
    public let recordID: String
    public let family: PromptFamily
    public let projectID: String?
    public let runID: String?
    public let nightID: Int64?
    public let featureIssueID: String?
    public let workCardIssueID: String?
    public let cardID: Int64?
    public let attemptID: Int64?
    public let round: Int?
    public let routeTry: Int?

    public init(
        recordID: String,
        family: PromptFamily,
        projectID: String? = nil,
        runID: String? = nil,
        nightID: Int64? = nil,
        featureIssueID: String? = nil,
        workCardIssueID: String? = nil,
        cardID: Int64? = nil,
        attemptID: Int64? = nil,
        round: Int? = nil,
        routeTry: Int? = nil
    ) {
        self.recordID = recordID.lowercased()
        self.family = family
        self.projectID = projectID
        self.runID = runID
        self.nightID = nightID
        self.featureIssueID = featureIssueID
        self.workCardIssueID = workCardIssueID
        self.cardID = cardID
        self.attemptID = attemptID
        self.round = round
        self.routeTry = routeTry
    }

    /// The storage scope for this provenance: project-scoped when a valid ProjectID is present,
    /// or machine-scoped for diagnostic dispatches.
    public var scope: DispatchPromptScope {
        if let projectID, let id = ProjectID(rawValue: projectID) {
            return .project(id)
        }
        return .machine
    }
}
