import Config
import Domain
import Engine

extension Doctor {
    /// Every workflow state and label Yellowhammer provisions in each team of `project`'s Linear project,
    /// verified read-only through the same checks setup runs (Diagnose the Installation, Check 4: "every
    /// provisioned or mapped item exists"). A missing item or a collision is a failure until it is
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
        do {
            if fix {
                report = try await BoardProvisioner.provision(
                    using: board, projectName: project.name, createIn: nil
                )
            } else {
                report = try await BoardProvisioner.verify(
                    using: board, projectName: project.name
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
            return [provisioning(
                .pass, "every workflow state and label Yellowhammer provisions is present in team \(teams)"
            )]
        }
        return failures.map { provisioning(.failure, $0) }
    }
}
