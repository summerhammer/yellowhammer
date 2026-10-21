import Domain

/// Reads the footprint ids an Act works with from a Board Mapping and the ids earlier provisioning
/// persisted (board-projection/provision-the-board): the mapping wins, then the persisted id, and each is
/// re-verified against what the team holds now. A name alone is never consulted here.
enum BoardFootprintLookup {
    /// The custom workflow-state ids (`Waiting on You`, `Blocked`) for `team`: a mapped or persisted id whose
    /// state still exists with category `started`. With `store` nil (a board bound with no footprint: test
    /// fakes) a `started` state of the provisioned name stands in, as before P22.8.
    static func customStateIDs(
        team: BoardObjectID, states: [BoardWorkflowState], mapping: BoardMapping,
        footprint store: (any BoardFootprintStore)?
    ) -> [BoardMappingRole: BoardObjectID] {
        let persisted = (try? store?.persistedFootprint()) ?? []
        var ids: [BoardMappingRole: BoardObjectID] = [:]
        for role in BoardMappingRole.customStates {
            let candidates = [mapping[role], persisted.first { $0.team == team && $0.role == role }?.objectID]
            if let id = candidates.compactMap({ $0 }).first(where: { id in
                states.contains { $0.id == id && $0.category == .started }
            }) {
                ids[role] = id
            } else if store == nil, let name = role.customStateName,
                      let byName = states.first(where: {
                          $0.category == .started && $0.name.lowercased() == name.lowercased()
                      }) {
                ids[role] = byName.id
            }
        }
        return ids
    }

    /// The `Card Type` label ids a mapping entry or a persisted id names, for those still present as labels.
    static func cardTypeLabelIDs(
        team: BoardObjectID, labels: [BoardLabel], mapping: BoardMapping,
        footprint store: (any BoardFootprintStore)?
    ) -> [CardType: BoardObjectID] {
        let persisted = (try? store?.persistedFootprint()) ?? []
        var ids: [CardType: BoardObjectID] = [:]
        for role in BoardMappingRole.cardTypeLabels {
            guard let type = role.cardType else { continue }
            let candidates = [mapping[role], persisted.first { $0.team == team && $0.role == role }?.objectID]
            if let id = candidates.compactMap({ $0 }).first(where: { id in
                labels.contains { $0.id == id && !$0.isGroup }
            }) {
                ids[type] = id
            }
        }
        return ids
    }
}
