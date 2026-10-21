import Config
import Domain
import Engine
import Foundation

extension Doctor {
    /// What `--fix` wrote (or could not write) to a Project's `[board.linear.mapping]`.
    struct MappingAdoption {
        let succeeded: Bool
        let mapping: BoardMapping
        let messages: [String]
    }

    /// `yh doctor --fix` as the Operator's gesture for an already-provisioned board: for each custom state
    /// (`waiting_on_you`, `blocked`) that collides only because no persisted id, mapping or Journal provenance
    /// exists, and that has exactly one same-name `started` candidate in exactly one team, the candidate's id
    /// is written to the Project file's `[board.linear.mapping]`. Zero or several candidates, or a role the
    /// file already maps, write nothing for that meaning (the collision stays a diagnostic with its lines).
    /// A second same-name state is never created and no other meaning is touched. The file is edited as text
    /// (comments, order and other content kept), validated by the loader and written atomically.
    func adoptSingleCandidates(in report: ProvisioningReport, project: ProjectConfiguration) -> MappingAdoption? {
        struct Adoption {
            let role: BoardMappingRole
            let id: BoardObjectID
            let name: String
        }
        var adoptions: [Adoption] = []
        for role in BoardMappingRole.customStates where project.boardMapping[role] == nil {
            let collisions = report.entries.filter { entry in
                guard case .workflowState(let name, _) = entry.subject, name == role.customStateName else {
                    return false
                }
                return entry.outcome == .collision("team")
            }
            guard collisions.count == 1, let entry = collisions.first, entry.candidates.count == 1,
                  let id = entry.candidates.first, case .workflowState(let name, _) = entry.subject else { continue }
            adoptions.append(Adoption(role: role, id: id, name: name))
        }
        guard !adoptions.isEmpty else { return nil }
        let file = configurationDirectory.appending(
            components: "projects", "\(project.id.rawValue).toml", directoryHint: .notDirectory
        )
        let path = file.path(percentEncoded: false)
        let described = adoptions.map { "\($0.role.rawValue) = \"\($0.id)\" (state `\($0.name)`)" }
        do {
            let original = try String(contentsOf: file, encoding: .utf8)
            let edited = BoardMappingFileEdit.adding(adoptions.map { ($0.role, $0.id) }, to: original)
            try Configuration.save(edited, to: file, in: configurationDirectory, replacing: original)
        } catch {
            return MappingAdoption(
                succeeded: false, mapping: project.boardMapping,
                messages: ["could not write the Board Mapping to \(path): \(error)"]
            )
        }
        var mapping = project.boardMapping
        for adoption in adoptions { mapping.ids[adoption.role] = adoption.id }
        return MappingAdoption(
            succeeded: true, mapping: mapping,
            messages: ["wrote to [board.linear.mapping] in \(path): " + described.joined(separator: ", ")]
        )
    }
}
