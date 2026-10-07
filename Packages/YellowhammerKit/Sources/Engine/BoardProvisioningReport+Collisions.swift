import Domain

extension ProvisioningReport {
    /// What to do about each collision: rename or delete the existing item that holds the name, then
    /// re-run setup. Creating the item by hand would collide too, so collisions never appear in
    /// ``createByHandGuideline``. A group-name collision gets one line; the children it blocks are
    /// covered by it. Nil when nothing collides.
    public var collisionGuideline: String? {
        let lines = entries.compactMap { entry -> String? in
            guard case .collision = entry.outcome else { return nil }
            let existing = entry.collidesWith ?? "the existing item of that name"
            switch entry.subject {
            case .workflowState(let name, let team):
                return "- rename or delete the \(existing) in team \(team.key); it holds the name of "
                    + "workflow state `\(name)` (category started)"
            case .labelGroup(let name, let team):
                return "- rename or delete the \(existing) in team \(team.key); it holds the name of "
                    + "label group `\(name)`"
            case .label(let name, let group, let team):
                return "- rename or delete the \(existing) in team \(team.key); it holds the name of "
                    + "label `\(name)` in group `\(group)`"
            case .linearProject, .team:
                return nil
            }
        }
        guard !lines.isEmpty else { return nil }
        return (["To finish in Linear, then re-run setup (it re-verifies afterwards):"] + lines)
            .joined(separator: "\n")
    }
}
