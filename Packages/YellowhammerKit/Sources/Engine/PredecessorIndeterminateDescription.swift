import Domain

/// Stable, per-repository descriptions shared by the Feature Card and Night Summary.
enum PredecessorIndeterminateDescription {
    static func notes(_ repositories: [String: PredecessorIndeterminateCause]) -> String {
        repositories.sorted { $0.key < $1.key }.map { repository, cause in
            switch cause {
            case .tipUnreadable:
                "[\(repository): pushed tip could not be read; merge observation indeterminate]"
            case .landingCommitUnreadable:
                "[\(repository): merged into mainline; landing commit could not be read]"
            }
        }.joined(separator: " ")
    }
}
