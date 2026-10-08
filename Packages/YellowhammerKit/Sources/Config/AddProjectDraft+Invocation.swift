import Domain
import Foundation

// MARK: - Invocation

extension AddProjectDraft {
    /// The `yh setup --init` call for this draft: the Project and its scheduled jobs, nothing
    /// machine-wide (no credentials, CLIs, route or Operator).
    public var setupInvocation: SetupInvocation {
        let linear: SetupInvocation.LinearProject = switch linearChoice {
        case .existing: .existing(linearProjectID.trimmingCharacters(in: .whitespacesAndNewlines))
        case .createInTeam: .createInTeam(key: teamKey ?? "")
        }
        let spec = specSourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = Schedule()
        let project = SetupInvocation.Project(
            id: projectID.trimmingCharacters(in: .whitespacesAndNewlines),
            name: name,
            linearProject: linear,
            specSource: specChoice == .path && !spec.isEmpty ? spec : nil,
            repos: repos.map {
                SetupInvocation.Repo(
                    name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    role: $0.role.trimmingCharacters(in: .whitespacesAndNewlines),
                    path: $0.path.trimmingCharacters(in: .whitespacesAndNewlines),
                    check: $0.check.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            },
            nightStart: schedule.nightStart == defaults.nightStart ? nil : "\(schedule.nightStart)",
            nightEnd: schedule.nightEnd == defaults.nightEnd ? nil : "\(schedule.nightEnd)",
            buildEveryMinutes: schedule.buildEveryMinutes == defaults.buildEveryMinutes
                ? nil : schedule.buildEveryMinutes
        )
        let jobs: SetupInvocation.Jobs = switch self.jobs {
        case .install: .install
        case .notNow: .notNow
        case .export:
            .export(
                directory: exportDirectory.trimmingCharacters(in: .whitespacesAndNewlines), cron: exportUsesCron
            )
        }
        // The GitHub step checks and stores the token of the default connection (`yh setup --print-github` and
        // `--install-github` with no name), so the new Project selects that one.
        return SetupInvocation(
            boardConnection: linearInstallationName, codeHostingConnection: CodeHostingConnection.defaultName,
            project: project, jobs: jobs
        )
    }

    /// The Bounds to write after `yh setup --init` exited with `status`: nil unless it succeeded and
    /// they differ from the defaults, which are never written.
    public func boundsToWrite(afterExitStatus status: Int32) -> Bounds? {
        status == 0 && !bounds.isDefault ? bounds : nil
    }
}
