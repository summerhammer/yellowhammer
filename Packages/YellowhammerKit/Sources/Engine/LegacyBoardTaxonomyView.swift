import Domain

/// The retired taxonomy a team still carries, resolved from what the board reports in one Act: the
/// retired settlement states (by provisioned name **and** `started` category, never one of Yellowhammer's
/// own custom states) and the children of the retired `Block Reason` and `Override` label groups. It is
/// what the legacy Board migration (roadmap P22.9) reads tracked issues against; it is never persisted,
/// since nothing here has a meaning of its own.
struct LegacyBoardTaxonomyView: Equatable {
    /// Each retired settlement state, by id.
    var settleStates: [BoardObjectID: BoardWorkflowState] = [:]
    /// Each `Block Reason` child label, by lowercased name.
    var blockReasonLabels: [String: BoardObjectID] = [:]
    /// Each `Override` child label, by lowercased name, with the name as the board spells it.
    var overrideLabels: [String: (name: String, id: BoardObjectID)] = [:]

    var isEmpty: Bool { settleStates.isEmpty && blockReasonLabels.isEmpty && overrideLabels.isEmpty }

    /// The label ids a pending write must not add: every retired child.
    var retiredLabelIDs: Set<BoardObjectID> {
        Set(blockReasonLabels.values).union(overrideLabels.values.map(\.id))
    }

    init(states: [BoardWorkflowState], labels: [BoardLabel], customStateIDs: Set<BoardObjectID>) {
        for state in states
        where LegacyBoardTaxonomy.isRetiredSettleState(state) && !customStateIDs.contains(state.id) {
            settleStates[state.id] = state
        }
        func children(ofGroup name: String) -> [BoardLabel] {
            guard let group = labels.first(where: { $0.isGroup && $0.name.lowercased() == name.lowercased() })
            else { return [] }
            return labels.filter { $0.parent == group.id }
        }
        for label in children(ofGroup: LegacyBoardTaxonomy.blockReasonGroup)
        where blockReasonLabels[label.name.lowercased()] == nil {
            blockReasonLabels[label.name.lowercased()] = label.id
        }
        for label in children(ofGroup: LegacyBoardTaxonomy.overrideGroup)
        where overrideLabels[label.name.lowercased()] == nil {
            overrideLabels[label.name.lowercased()] = (label.name, label.id)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.settleStates == rhs.settleStates && lhs.blockReasonLabels == rhs.blockReasonLabels
            && lhs.overrideLabels.mapValues(\.id) == rhs.overrideLabels.mapValues(\.id)
    }
}
