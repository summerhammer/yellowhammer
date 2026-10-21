import Domain

/// Label-group provisioning, split out of `BoardProvisioner.swift` to stay under the file-length limit.
extension BoardProvisioner {
    static func provisionGroup(
        board: Target,
        group: LabelGroupDeclaration,
        snapshot: TeamSnapshot,
        into entries: inout [ProvisioningEntry]
    ) async throws(BoardError) {
        let (team, existingLabels) = (snapshot.team, snapshot.labels)
        // Check for group collisions: any non-group label with group's name.
        let groupCollision = existingLabels.first { label in
            label.name.lowercased() == group.name.lowercased() && !label.isGroup
        }
        if let collision = groupCollision {
            reportGroupNameCollision(collision, group: group, board: board, snapshot: snapshot, into: &entries)
            return
        }
        let groupExists = existingLabels.contains { $0.name.lowercased() == group.name.lowercased() && $0.isGroup }
        guard groupExists || board.createsMissing else {
            entries.append(ProvisioningEntry(
                subject: .labelGroup(group.name, team: team), outcome: .missing(notProvisioned)
            ))
            for child in group.children {
                let reused = board.labelOverride(child, among: existingLabels, team: team.id)
                entries.append(ProvisioningEntry(
                    subject: .label(child, group: group.name, team: team),
                    outcome: reused == nil ? .missing(notProvisioned) : .present, id: reused
                ))
            }
            return
        }
        let groupId: BoardObjectID
        do {
            groupId = try await ensureGroupExists(
                board: board, groupName: group.name, team: team, existingLabels: existingLabels, into: &entries
            )
        } catch .forbidden(let reason) {
            // The group itself could not be created, so none of its children can be either — each is
            // reported blocked, mirroring the group-name-collision path above, and setup moves on.
            reportGroupCreationRefused(group: group, team: team, reason: reason, into: &entries)
            return
        }
        let context = ChildLabelContext(group: group, team: team, groupId: groupId)
        for childName in group.children {
            try await provisionChildLabel(
                board: board, childName: childName, context: context, existingLabels: existingLabels, into: &entries
            )
        }
    }

    /// A non-group label holds the group's name: the group is a collision and blocks its children, except
    /// those a Board Mapping or a persisted id already names.
    private static func reportGroupNameCollision(
        _ collision: BoardLabel, group: LabelGroupDeclaration, board: Target, snapshot: TeamSnapshot,
        into entries: inout [ProvisioningEntry]
    ) {
        let (team, labels) = (snapshot.team, snapshot.labels)
        entries.append(ProvisioningEntry(
            subject: .labelGroup(group.name, team: team),
            outcome: .collision(scopeDescription(collision.team)),
            collidesWith: describe(collision, among: labels)
        ))
        for child in group.children {
            let subject = ProvisioningEntry.Subject.label(child, group: group.name, team: team)
            if let reused = board.labelOverride(child, among: labels, team: team.id) {
                entries.append(ProvisioningEntry(subject: subject, outcome: .present, id: reused))
            } else {
                entries.append(ProvisioningEntry(subject: subject, outcome: .blocked("group name collision")))
            }
        }
    }

    /// The fields every child label of one group shares — bundled purely to keep
    /// ``provisionChildLabel(board:childName:context:existingLabels:into:)`` under the parameter-count
    /// limit.
    struct ChildLabelContext {
        let group: LabelGroupDeclaration
        let team: BoardTeam
        let groupId: BoardObjectID
    }

    static func reportGroupCreationRefused(
        group: LabelGroupDeclaration, team: BoardTeam, reason: String, into entries: inout [ProvisioningEntry]
    ) {
        entries.append(ProvisioningEntry(
            subject: .labelGroup(group.name, team: team), outcome: .permissionRefused(reason)
        ))
        // Reported as a permission refusal too, not `.blocked`: the group-name-collision path's
        // `.blocked` means "rename the colliding label", which is the wrong advice here — the group
        // itself is what needs the create-by-hand guideline.
        for child in group.children {
            entries.append(ProvisioningEntry(
                subject: .label(child, group: group.name, team: team),
                outcome: .permissionRefused("its group `\(group.name)` could not be created: \(reason)")
            ))
        }
    }

    static func provisionChildLabel(
        board: Target,
        childName: String,
        context: ChildLabelContext,
        existingLabels: [BoardLabel],
        into entries: inout [ProvisioningEntry]
    ) async throws(BoardError) {
        let (group, team, groupId) = (context.group, context.team, context.groupId)
        let subject = ProvisioningEntry.Subject.label(childName, group: group.name, team: team)
        if let type = CardType(rawValue: childName), board.unusable.contains(BoardMappingRole(cardType: type)) {
            return // its Board Mapping entry failed verification and is reported; nothing is made in its place
        }
        if let reused = board.labelOverride(childName, among: existingLabels, team: team.id) {
            // A Board Mapping entry, or the id persisted by earlier provisioning, verified present.
            entries.append(ProvisioningEntry(subject: subject, outcome: .present, id: reused))
            return
        }
        let child = existingLabels.first { $0.name.lowercased() == childName.lowercased() && $0.parent == groupId }
        if let child {
            entries.append(ProvisioningEntry(subject: subject, outcome: .present, id: child.id))
            return
        }
        let collision = existingLabels.first { label in
            label.name.lowercased() == childName.lowercased() && label.parent != groupId
        }
        if let collision {
            let outcome = ProvisioningEntry.Outcome.collision(scopeDescription(collision.team))
            entries.append(ProvisioningEntry(
                subject: subject, outcome: outcome, collidesWith: describe(collision, among: existingLabels)
            ))
            return
        }
        guard board.createsMissing else {
            entries.append(ProvisioningEntry(subject: subject, outcome: .missing(notProvisioned)))
            return
        }
        do {
            let created = try await board.createLabel(name: childName, team: team.id, isGroup: false, parent: groupId)
            entries.append(ProvisioningEntry(subject: subject, outcome: .created, id: created.id))
        } catch .forbidden(let reason) {
            entries.append(ProvisioningEntry(subject: subject, outcome: .permissionRefused(reason)))
        }
    }

    /// The existing label holding a provisioned name, as the Operator would find it in Linear: with its
    /// parent group, so a same-name label under another group is named by both.
    static func describe(_ label: BoardLabel, among existingLabels: [BoardLabel]) -> String {
        let kind = label.team == nil ? "workspace label" : "label"
        if label.isGroup {
            return "\(kind) group `\(label.name)`"
        }
        guard let parent = label.parent else {
            return "\(kind) `\(label.name)` (not in a group)"
        }
        let parentName = existingLabels.first { $0.id == parent }?.name
        return "\(kind) `\(label.name)` in group `\(parentName ?? "another group")`"
    }

    static func ensureGroupExists(
        board: Target,
        groupName: String,
        team: BoardTeam,
        existingLabels: [BoardLabel],
        into entries: inout [ProvisioningEntry]
    ) async throws(BoardError) -> BoardObjectID {
        let existingGroup = existingLabels.first { label in
            label.name.lowercased() == groupName.lowercased() && label.isGroup
        }
        if let existing = existingGroup {
            entries.append(ProvisioningEntry(
                subject: .labelGroup(groupName, team: team),
                outcome: .present
            ))
            return existing.id
        }
        let created = try await board.createLabel(
            name: groupName,
            team: team.id,
            isGroup: true,
            parent: nil
        )
        entries.append(ProvisioningEntry(
            subject: .labelGroup(groupName, team: team),
            outcome: .created
        ))
        return created.id
    }
}
