import Domain

/// Selects the team's native workflow state for a category (board-projection/provision-the-board): an
/// explicit Board Mapping wins; otherwise the lowest-`position` eligible state, a position tie broken by
/// the state's stable id. A display name never decides a category.
///
/// Eligible means: the right category, and not one of Yellowhammer's own custom states. The custom ids
/// come from the footprint (mapped or persisted).
public enum NativeStateSelection {
    /// The state `role` selects among `states`, or nil when the team has none (or a mapping fails).
    /// A mapping that does not name a state of `category` selects nothing: it is reported by verification,
    /// and nothing is inferred from a name or a category in its place.
    public static func select(
        category: BoardWorkflowStateCategory,
        mapped: BoardObjectID?,
        among states: [BoardWorkflowState],
        excluding customIDs: Set<BoardObjectID>
    ) -> BoardWorkflowState? {
        if let mapped {
            return states.first { $0.id == mapped && $0.category == category }
        }
        return states
            .filter { $0.category == category && isEligible($0, excluding: customIDs) }
            .min { lhs, rhs in
                let (lp, rp) = (lhs.position ?? .infinity, rhs.position ?? .infinity)
                return lp != rp ? lp < rp : lhs.id.rawValue < rhs.id.rawValue
            }
    }

    private static func isEligible(_ state: BoardWorkflowState, excluding customIDs: Set<BoardObjectID>) -> Bool {
        !customIDs.contains(state.id)
    }
}
