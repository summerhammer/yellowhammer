import Config
import Domain
import Engine

extension Doctor {
    /// The two custom workflow states and three `Card Type` labels Yellowhammer provisions, the native
    /// category selections and the Board Mapping, in each team of `project`'s Linear project, verified
    /// read-only through the same checks setup runs (Diagnose the Installation, Check 4: "every
    /// provisioned or mapped item exists"). A collision prints the Board Mapping lines that would adopt the
    /// existing state; a missing native category or a mapping that fails verification is a failure. Mappings
    /// of Projects on one Linear project that disagree are refused earlier, at load. A missing item or a collision is a failure until it is
    /// fixed, so a board setup could not finish never passes (#361). Run only once the membership check
    /// passed: a team Yellowhammer is not a member of, or a Linear project it cannot read, is reported
    /// once, there. The Card override is a description field, so no `Override` label group is verified.
    func boardProvisioningFindings(
        project: ProjectConfiguration, installation: LinearInstallation, scope: DoctorInstallationScope
    ) async -> [DoctorFinding] {
        let prefix = "Project \(project.id) (Board Connection \(installation.name)): " // glossary:ignore GL001
        func provisioning(_ severity: DoctorSeverity, _ message: String) -> DoctorFinding {
            finding(
                .linear, subject: "provisioning", severity, prefix + message, project: project.id, installation: scope
            )
        }

        let board = bindProvisioning(installation, project.linearProject)
        let report: ProvisioningReport
        let store = footprintStore(for: project, installation: installation)
        let footprint = BoardFootprintInputs(mapping: project.boardMapping, store: store)
        do {
            if fix {
                report = try await BoardProvisioner.provision(
                    using: board, projectName: project.name, createIn: nil, footprint: footprint
                )
                // `--fix` records what it resolved; a plain run only reports (read-only).
                try? store.recordFootprint(report.footprint)
            } else {
                report = try await BoardProvisioner.verify(
                    using: board, projectName: project.name, footprint: footprint
                )
            }
        } catch {
            // Never silent: a board doctor cannot read is not a board that passes.
            return [provisioning(
                .failure, "the team's workflow states and labels could not be \(fix ? "repaired" : "read"): \(error)"
            )]
        }
        let failures = report.unfinishedSteps + (fix ? report.entries.compactMap { entry -> String? in
            switch entry.outcome {
            case .refused(let reason), .notAMember(let reason):
                return "\(entry.subject): \(reason)"
            case .missing(let reason):
                if case .linearProject = entry.subject { return "\(entry.subject): \(reason)" }
                return nil
            default:
                return nil
            }
        } : [])
        guard !failures.isEmpty else {
            let teams = report.linearProject?.teams.map(\.key).joined(separator: ", ") ?? ""
            guard !teams.isEmpty else { return [] }
            let note = BoardFootprintBinding.retiredNote(project.boardMapping).map { " (\($0))" } ?? ""
            return [provisioning(
                .pass, "the two custom workflow states, the native category selections and the three Card Type "
                    + "labels resolve in team \(teams)" + note
            )]
        }
        return failures.map { provisioning(.failure, $0) }
    }

    /// `--fix` opens (creating) the Project's Journal so what it resolves is recorded; a plain run only reads.
    private func footprintStore(
        for project: ProjectConfiguration, installation: LinearInstallation
    ) -> any BoardFootprintStore {
        guard fix else {
            return BoardFootprintBinding.readOnly(configurationDirectory: configurationDirectory, projectID: project.id)
        }
        return BoardFootprintBinding.writable(
            configurationDirectory: configurationDirectory, project: project, workspace: installation.workspace
        ).store
    }
}
