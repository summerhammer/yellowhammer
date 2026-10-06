import Config
import Domain

extension Doctor {
    /// The Yellowhammer identity's team membership in each team of `project`'s Linear project, read through the
    /// installation that serves the Project (Board Provisioning Ruling, OQ80). Provisioned items (states,
    /// labels) are not verified here.
    func boardMembershipFindings(
        project: ProjectConfiguration, installation: LinearInstallation, workspaceName: String?
    ) async -> [DoctorFinding] {
        let scope = DoctorInstallationScope(
            name: installation.name, workspace: installation.workspace.rawValue,
            workspaceName: workspaceName, projects: [project.id]
        )
        let prefix = "Project \(project.id) (Board Connection \(installation.name)): " // glossary:ignore GL001
        func team(_ severity: DoctorSeverity, _ message: String) -> DoctorFinding {
            finding(.linear, subject: "team", severity, prefix + message, project: project.id, installation: scope)
        }

        let board = bindProvisioning(installation, project.linearProject)
        let linearProject: BoardProjectScope
        let memberTeams: Set<BoardObjectID>
        do {
            linearProject = try await board.linearProject()
            memberTeams = Set(try await board.memberTeams())
        } catch .forbidden {
            return [team(
                .failure,
                "Linear refused permission to read Linear project \(project.linearProject) for this connection; " +
                    "check the app's access in Linear"
            )]
        } catch .scopeNotFound {
            return [team(
                .failure,
                "Linear project \(project.linearProject) is not visible to this connection; " +
                    "select its team when approving the app, or re-connect the workspace: " +
                    Self.reconnectFix(installation)
            )]
        } catch {
            return [team(.failure, "Linear project \(project.linearProject) could not be read: \(error)")]
        }

        let missing = linearProject.teams.filter { !memberTeams.contains($0.id) }
        guard !missing.isEmpty else {
            return [team(.pass, "Yellowhammer is a member of every team of Linear project \(project.linearProject)")]
        }
        return missing.map {
            team(
                .failure,
                "Yellowhammer is not a member of team \($0.key); add Yellowhammer as a member in the team's " +
                    "Settings → Members"
            )
        }
    }
}
