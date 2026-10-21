import Domain

/// The two custom workflow states, the native categories and the Board Mapping (board-projection/
/// provision-the-board, P22.8), split out of `BoardProvisioner.swift` to stay under the file-length limit.
extension BoardProvisioner {
    /// One member team as a run read it: its workflow states and its labels.
    struct TeamSnapshot {
        let team: BoardTeam
        let states: [BoardWorkflowState]
        let labels: [BoardLabel]
    }

    // MARK: - Board Mapping

    /// What verifying a Board Mapping against the teams a run read produced.
    struct MappingVerification {
        /// The entries that passed, for the run to use.
        let mapping: BoardMapping
        /// The roles whose entry failed: reported, and never filled by anything else.
        let unusable: Set<BoardMappingRole>
        /// A `.invalidMapping` report for each entry that failed.
        let entries: [ProvisioningEntry]
    }

    /// Verifies every entry of `mapping` against the teams the run read: the id exists, has the role's
    /// category (a label role: is a label, not a group), and serves one meaning only. Returns the entries
    /// that passed, for the run to use, and a `.invalidMapping` report for each that did not. Nothing is
    /// inferred from a matching name in place of a failed entry.
    static func verifyMapping(
        _ mapping: BoardMapping, against snapshots: [TeamSnapshot]
    ) -> MappingVerification {
        var valid: [BoardMappingRole: BoardObjectID] = [:]
        var entries: [ProvisioningEntry] = []
        func invalid(_ role: BoardMappingRole, _ reason: String) {
            entries.append(ProvisioningEntry(subject: .boardMapping(role.rawValue), outcome: .invalidMapping(reason)))
        }
        for role in BoardMappingRole.allCases {
            guard let id = mapping[role] else { continue }
            let owners = BoardMappingRole.allCases.filter { mapping[$0] == id }
            if owners.count > 1 {
                let others = owners.filter { $0 != role }.map(\.rawValue).joined(separator: ", ")
                invalid(role, "id \(id) also serves \(others); no id serves two meanings")
                continue
            }
            if let category = role.category {
                let found = snapshots.flatMap(\.states).first { $0.id == id }
                guard let found else {
                    invalid(role, "no workflow state with id \(id) in the Project's team(s)")
                    continue
                }
                guard found.category == category else {
                    let actual = found.category.map { "category \(categoryName($0))" } ?? "an unknown category"
                    invalid(role, "workflow state `\(found.name)` (\(id)) is \(actual); \(role.rawValue) needs "
                        + "category \(categoryName(category))")
                    continue
                }
            } else {
                let found = snapshots.flatMap(\.labels).first { $0.id == id }
                guard let found, !found.isGroup else {
                    invalid(role, found == nil
                        ? "no label with id \(id) in the Project's team(s)"
                        : "id \(id) is a label group, not a label")
                    continue
                }
            }
            valid[role] = id
        }
        let unusable = Set(mapping.ids.keys).subtracting(valid.keys)
        return MappingVerification(
            mapping: BoardMapping(ids: valid, retiredKeys: mapping.retiredKeys), unusable: unusable, entries: entries
        )
    }

    /// Linear's spelling of a category: Yellowhammer's `shelved` is Linear's `canceled`.
    static func categoryName(_ category: BoardWorkflowStateCategory) -> String {
        category == .shelved ? "canceled" : category.rawValue
    }

    // MARK: - The two custom workflow states

    /// Provisions one custom state. In order: a Board Mapping entry for it; the id persisted by earlier
    /// provisioning, verified present with category `started`; a same-name `started` state on this Project's
    /// own Journal provenance (a write Yellowhammer delivered that set it), recorded as bootstrapped; or,
    /// when no same-name state exists, a create. A same-name state with none of those is a collision, never
    /// reused and never a reason to create a second one. A matching name alone is never sufficient.
    static func provisionCustomState(
        _ role: BoardMappingRole,
        board: Target,
        team: BoardTeam,
        existingStates: [BoardWorkflowState],
        into entries: inout [ProvisioningEntry]
    ) async throws(BoardError) {
        guard let name = role.customStateName, !board.unusable.contains(role) else { return }
        let subject = ProvisioningEntry.Subject.workflowState(name, team: team)
        // A mapping entry was verified against every team already; it names this team's state only if the
        // state is in this team (a Linear project may span teams, each with its own custom states).
        if let mapped = board.mapping[role], let state = existingStates.first(where: { $0.id == mapped }) {
            entries.append(ProvisioningEntry(subject: subject, outcome: .present, id: state.id))
            return
        }
        let persisted = board.persisted.first { $0.team == team.id && $0.role == role }
        if let persisted, let state = existingStates.first(where: { $0.id == persisted.objectID }),
           state.category == provisionedStateCategory {
            entries.append(ProvisioningEntry(subject: subject, outcome: .present, id: state.id))
            return
        }
        let sameName = existingStates.filter { $0.name.lowercased() == name.lowercased() }
        if sameName.isEmpty {
            await createCustomState(name: name, board: board, team: team, subject: subject, into: &entries)
            return
        }
        // A run bound with no footprint store at all (test fakes) has nothing to prove provenance with, and
        // takes a `started` state of the provisioned name, as before P22.8. Every real caller passes a store.
        if board.store == nil, let byName = sameName.first(where: { $0.category == provisionedStateCategory }) {
            entries.append(ProvisioningEntry(subject: subject, outcome: .present, id: byName.id))
            return
        }
        for candidate in sameName where candidate.category == provisionedStateCategory {
            let provenance = (try? board.store?.hasDeliveredStateWrite(to: candidate.id)) ?? false
            if provenance {
                entries.append(ProvisioningEntry(subject: subject, outcome: .present, id: candidate.id))
                return
            }
        }
        entries.append(collision(role, sameName: sameName, subject: subject))
    }

    private static func createCustomState(
        name: String, board: Target, team: BoardTeam, subject: ProvisioningEntry.Subject,
        into entries: inout [ProvisioningEntry]
    ) async {
        guard board.createsMissing else {
            entries.append(ProvisioningEntry(subject: subject, outcome: .missing(notProvisioned)))
            return
        }
        do {
            let created = try await board.createWorkflowState(
                name: name, category: provisionedStateCategory, team: team.id
            )
            entries.append(ProvisioningEntry(subject: subject, outcome: .created, id: created.id))
        } catch .forbidden(let reason) {
            // A permission refusal is reported by name — never as the Project's Linear project being
            // invisible — and setup moves on to the next workflow state (Refusals Ruling).
            entries.append(ProvisioningEntry(subject: subject, outcome: .permissionRefused(reason)))
        } catch {
            entries.append(ProvisioningEntry(subject: subject, outcome: .permissionRefused("\(error)")))
        }
    }

    private static func collision(
        _ role: BoardMappingRole, sameName: [BoardWorkflowState], subject: ProvisioningEntry.Subject
    ) -> ProvisioningEntry {
        let described = sameName.map { state -> String in
            let category = state.category.map { "category \(categoryName($0))" } ?? "an unknown category"
            return "workflow state `\(state.name)` (\(state.id)) of \(category)"
        }
        let adoptable = sameName.filter { $0.category == provisionedStateCategory }
        let hint = adoptable.isEmpty ? nil : (["[board.linear.mapping]"] + adoptable.map {
            "\(role.rawValue) = \"\($0.id)\""
        }).joined(separator: "\n")
        return ProvisioningEntry(
            subject: subject, outcome: .collision("team"), collidesWith: described.joined(separator: " and "),
            mappingHint: hint
        )
    }

    // MARK: - Native categories

    /// Reports, for each native category Yellowhammer uses, whether the team has a state to select. A
    /// category the team lacks is an actionable incomplete step naming the category and the team; a
    /// substitute is never created. A mapped state satisfies its category.
    static func reportNativeCategories(
        board: Target, team: BoardTeam, states: [BoardWorkflowState], into entries: inout [ProvisioningEntry]
    ) {
        let customIDs = Set(BoardMappingRole.customStates.compactMap { role in
            board.mapping[role].flatMap { id in states.first { $0.id == id }?.id }
                ?? board.persisted.first { $0.team == team.id && $0.role == role }?.objectID
        })
        for role in BoardMappingRole.nativeStates {
            // A mapping that failed verification is reported on its own; nothing is selected in its place.
            guard let category = role.category, !board.unusable.contains(role) else { continue }
            let subject = ProvisioningEntry.Subject.nativeCategory(role.rawValue, team: team)
            let selected = NativeStateSelection.select(
                category: category, mapped: board.mapping[role].flatMap { id in
                    states.contains { $0.id == id } ? id : nil
                },
                among: states, excluding: customIDs
            )
            if let selected {
                entries.append(ProvisioningEntry(subject: subject, outcome: .present, id: selected.id))
            } else {
                entries.append(ProvisioningEntry(
                    subject: subject,
                    outcome: .missing(
                        "team \(team.key) has no `\(role.rawValue)` workflow state (category "
                        + "\(categoryName(category))); add one in the team's workflow settings — "
                        + "Yellowhammer does not create a substitute"
                    )
                ))
            }
        }
    }

    // MARK: - Records to persist

    /// The footprint ids the run resolved that the Journal does not already hold: a created object
    /// (`provisioned`), a mapped one (`mapped`), an existing one accepted on provenance or group
    /// membership (`bootstrapped`). Custom states and `Card Type` labels only; native states are selected
    /// afresh each Act and never persisted.
    static func footprintRecords(
        from entries: [ProvisioningEntry], mapping: BoardMapping, persisted: [BoardFootprintRecord]
    ) -> [BoardFootprintRecord] {
        entries.compactMap { entry -> BoardFootprintRecord? in
            guard let id = entry.id, let (role, team) = footprintRole(of: entry.subject) else { return nil }
            let source: BoardFootprintSource
            if entry.outcome == .created {
                source = .provisioned
            } else if mapping[role] == id {
                source = .mapped
            } else if persisted.contains(where: { $0.team == team.id && $0.role == role && $0.objectID == id }) {
                return nil
            } else {
                source = .bootstrapped
            }
            let record = BoardFootprintRecord(team: team.id, role: role, objectID: id, source: source)
            return persisted.contains(record) ? nil : record
        }
    }

    /// The footprint role and team a report subject stands for: a custom state or a `Card Type` label.
    private static func footprintRole(of subject: ProvisioningEntry.Subject) -> (BoardMappingRole, BoardTeam)? {
        switch subject {
        case .workflowState(let name, let team):
            BoardMappingRole.customStates.first { $0.customStateName == name }.map { ($0, team) }
        case .label(let name, _, let team):
            CardType(rawValue: name).map { (BoardMappingRole(cardType: $0), team) }
        default:
            nil
        }
    }
}
