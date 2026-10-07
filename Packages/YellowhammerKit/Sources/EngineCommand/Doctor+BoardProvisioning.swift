import Config
import Domain
import Engine

extension Doctor {
    /// Every workflow state and label Yellowhammer provisions in each team of `project`'s Linear project,
    /// verified read-only through the same checks setup runs (Diagnose the Installation, Check 4: "every
    /// provisioned or mapped item exists"). A missing item or a collision is a failure until it is
    /// fixed, so a board setup could not finish never passes (#361). Run only once the membership check
    /// passed: a team Yellowhammer is not a member of, or a Linear project it cannot read, is reported
    /// once, there. The `Override` group is not verified: no Act depends on it.
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
            report = try await BoardProvisioner.verify(using: board, projectName: project.name)
        } catch {
            // Never silent: a board doctor cannot read is not a board that passes.
            return [provisioning(.failure, "the team's workflow states and labels could not be read: \(error)")]
        }
        let failures = report.entries.compactMap { entry -> String? in
            Self.provisioningFailure(entry, in: report)
        }
        guard !failures.isEmpty else {
            let teams = report.linearProject?.teams.map(\.key).joined(separator: ", ") ?? ""
            guard !teams.isEmpty else { return [] }
            return [provisioning(
                .pass, "every workflow state and label Yellowhammer provisions is present in team \(teams)"
            )]
        }
        return failures.map { provisioning(.failure, $0) }
    }

    /// The failure message for one verified entry; nil when it needs no fix here. A label whose own
    /// group is missing or collides is covered by the group's failure, so a whole group never fails
    /// once per child.
    private static func provisioningFailure(_ entry: ProvisioningEntry, in report: ProvisioningReport) -> String? {
        switch entry.subject {
        case .linearProject, .team:
            // An invisible Linear project or a team without Yellowhammer is the membership finding's.
            return nil
        case .label(_, let group, let team) where !groupIsPresent(group, team: team, in: report):
            return nil
        case .label, .labelGroup, .workflowState:
            break
        }
        switch entry.outcome {
        case .missing(let reason):
            return "\(entry.subject) is missing: \(reason)"
        case .collision:
            let existing = entry.collidesWith ?? "an existing item of the same name"
            return "\(entry.subject) is not provisioned: its name is held by the \(existing); "
                + "rename or delete that one in Linear, then re-run `yh setup`"
        case .permissionRefused(let reason):
            return "\(entry.subject): permission refused (\(reason))"
        case .present, .created, .blocked, .notAMember, .refused:
            return nil
        }
    }

    private static func groupIsPresent(_ group: String, team: BoardTeam, in report: ProvisioningReport) -> Bool {
        report.entries.contains { entry in
            guard case .labelGroup(group, let groupTeam) = entry.subject, groupTeam == team else { return false }
            return entry.outcome == .present
        }
    }
}
