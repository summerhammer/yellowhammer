import Domain

extension ProjectConfigurationDecoder {
    /// `[board.linear.mapping]`: ids of existing Linear objects standing in for what Yellowhammer provisions
    /// or selects by category (board-projection/provision-the-board). Keys are ``BoardMappingRole`` raw
    /// values; each value is a non-empty string id, and no id may serve two meanings.
    func boardMapping(in linear: TOMLTable) throws(ConfigurationError) -> BoardMapping {
        guard let value = linear["mapping"] else { return .empty }
        let table = try decoding.table(value, key: "board.linear.mapping")
        try decoding.rejectUnknownKeys(
            in: table, path: "board.linear.mapping",
            allowed: Set(BoardMappingRole.allCases.map(\.rawValue))
        )
        var ids: [BoardMappingRole: BoardObjectID] = [:]
        var firstKey: [BoardObjectID: String] = [:]
        for role in BoardMappingRole.allCases {
            guard let string = try decoding.optionalString(role.rawValue, in: table, path: "board.linear.mapping")
            else { continue }
            let id = BoardObjectID(rawValue: string)
            if let first = firstKey[id] {
                throw decoding.error(
                    line: table[role.rawValue]?.line ?? table.line, key: "board.linear.mapping.\(role.rawValue)",
                    .duplicateMappingID(firstKey: first)
                )
            }
            firstKey[id] = role.rawValue
            ids[role] = id
        }
        return BoardMapping(ids: ids)
    }
}
