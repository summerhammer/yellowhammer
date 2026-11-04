/// Why a repository could not record an Observed Merge on a predecessor pass.
public enum PredecessorIndeterminateCause: String, Codable, Equatable, Sendable {
    case tipUnreadable
    case landingCommitUnreadable
}
