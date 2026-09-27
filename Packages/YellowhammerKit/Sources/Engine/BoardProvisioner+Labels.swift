import Domain

/// Label-group provisioning, split out of `BoardProvisioner.swift` to stay under the file-length limit.
extension BoardProvisioner {
    static func provisionGroup(
        board: any BoardProvisioning,
        group: LabelGroupDeclaration,
        team: BoardTeam,
        existingLabels: [BoardLabel],
        into entries: inout [ProvisioningEntry]
    ) async throws(BoardError) {
        // Check for group collisions: any non-group label with group's name.
        let groupCollision = existingLabels.first { label in
            label.name.lowercased() == group.name.lowercased() && !label.isGroup
        }
        if let collision = groupCollision {
            entries.append(ProvisioningEntry(
                subject: .labelGroup(group.name, team: team),
                outcome: .collision(scopeDescription(collision.team))
            ))
            for child in group.children {
                entries.append(ProvisioningEntry(
                    subject: .label(child, group: group.name, team: team),
                    outcome: .blocked("group name collision")
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
        board: any BoardProvisioning,
        childName: String,
        context: ChildLabelContext,
        existingLabels: [BoardLabel],
        into entries: inout [ProvisioningEntry]
    ) async throws(BoardError) {
        let (group, team, groupId) = (context.group, context.team, context.groupId)
        let subject = ProvisioningEntry.Subject.label(childName, group: group.name, team: team)
        let child = existingLabels.first { $0.name.lowercased() == childName.lowercased() && $0.parent == groupId }
        if child != nil {
            entries.append(ProvisioningEntry(subject: subject, outcome: .present))
            return
        }
        let collision = existingLabels.first { label in
            label.name.lowercased() == childName.lowercased() && label.parent != groupId
        }
        if let collision {
            let outcome = ProvisioningEntry.Outcome.collision(scopeDescription(collision.team))
            entries.append(ProvisioningEntry(subject: subject, outcome: outcome))
            return
        }
        do {
            _ = try await board.createLabel(name: childName, team: team.id, isGroup: false, parent: groupId)
            entries.append(ProvisioningEntry(subject: subject, outcome: .created))
        } catch .forbidden(let reason) {
            entries.append(ProvisioningEntry(subject: subject, outcome: .permissionRefused(reason)))
        }
    }

    static func ensureGroupExists(
        board: any BoardProvisioning,
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
