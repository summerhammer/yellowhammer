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
        let store = footprintStore(for: project, installation: installation)
        let report: ProvisioningReport
        var written: [DoctorFinding] = []
        do {
            var current = try await provisioningReport(board, project, store)
            if fix, let adoption = adoptSingleCandidates(in: current, project: project) {
                written = adoption.messages.map { provisioning(adoption.succeeded ? .info : .warning, $0) }
                if adoption.succeeded {
                    var adopted = project
                    adopted.boardMapping = adoption.mapping
                    current = try await provisioningReport(board, adopted, store)
                }
            }
            report = current
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
        let residual = await residualTaxonomyFindings(report: report, board: board, provisioning)
        guard !failures.isEmpty else {
            let teams = report.linearProject?.teams.map(\.key).joined(separator: ", ") ?? ""
            guard !teams.isEmpty else { return written + residual }
            let note = BoardFootprintBinding.retiredNote(project.boardMapping).map { " (\($0))" } ?? ""
            return written + [provisioning(
                .pass, "the two custom workflow states, the native category selections and the three Card Type "
                    + "labels resolve in team \(teams)" + note
            )] + residual
        }
        return written + failures.map { provisioning(.failure, $0) } + residual
    }

    /// The retired taxonomy earlier builds left on a team (roadmap P22.9): the settlement states `Kept in
    /// Flight` and `Abandoned` and the `Block Reason` and `Override` label groups. Information only: nothing
    /// reads them, nothing is deleted, and a team that cannot be read says nothing. Other Projects or people
    /// may still use them, so deleting is the Operator's call in Linear.
    private func residualTaxonomyFindings(
        report: ProvisioningReport, board: any BoardProvisioning,
        _ makeFinding: (DoctorSeverity, String) -> DoctorFinding
    ) async -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        for team in report.linearProject?.teams ?? [] {
            guard let states = try? await board.workflowStates(team: team.id),
                  let labels = try? await board.labels(team: team.id)
            else { continue }
            let items = LegacyBoardTaxonomy.residualItems(states: states, labels: labels)
            guard !items.isEmpty else { continue }
            findings.append(makeFinding(
                .info,
                "team \(team.key) still carries retired Yellowhammer taxonomy: \(items.joined(separator: ", ")). "
                    + "Retired, unused by Yellowhammer, safe to delete in Linear if no one else uses them."
            ))
        }
        return findings
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

    /// One provisioning (`--fix`) or verification run, recording what it resolved when it provisions.
    private func provisioningReport(
        _ board: any BoardProvisioning, _ project: ProjectConfiguration, _ store: any BoardFootprintStore
    ) async throws(BoardError) -> ProvisioningReport {
        let footprint = BoardFootprintInputs(mapping: project.boardMapping, store: store)
        guard fix else {
            return try await BoardProvisioner.verify(using: board, projectName: project.name, footprint: footprint)
        }
        let report = try await BoardProvisioner.provision(
            using: board, projectName: project.name, createIn: nil, footprint: footprint
        )
        try? store.recordFootprint(report.footprint)
        return report
    }
}
