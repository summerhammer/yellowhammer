import Config
import Domain
import Foundation

extension Doctor {
    /// Check: the GitHub credential. For every valid Project, the effective reference is its own
    /// `gitHubCredential` override or the machine default. Projects are grouped by reference and the
    /// token is read once per reference; each Project then gets one `credential` finding and one finding per
    /// working Repo (a Repo whose role is `spec` is skipped: the Spec Source is read-only, so nothing is
    /// pushed to it). Every finding is scoped to its Project.
    ///
    /// With no valid Project there is nothing to publish yet, so the machine default reference is checked on
    /// its own and reported as context (`info`) when it resolves or is absent.
    func runGitHubCheck(configuration: Configuration) async -> [DoctorFinding] {
        guard !configuration.projects.isEmpty else {
            let reference = configuration.machine.gitHubCredential
            let report = await gitHub.report(
                reference: reference, secret: lookUpSecret(reference), repos: []
            )
            return [defaultReferenceFinding(report)]
        }

        let projects = configuration.projects.filter { projectFilter == nil || $0.id == projectFilter }
        var references: [CredentialReference] = []
        for project in projects {
            let reference = configuration.machine.gitHubCredential(for: project)
            if !references.contains(reference) { references.append(reference) }
        }

        var findings: [DoctorFinding] = []
        for reference in references {
            let secret = lookUpSecret(reference)
            for project in projects where configuration.machine.gitHubCredential(for: project) == reference {
                let report = await gitHub.report(
                    reference: reference, secret: secret, repos: workingRepos(of: project)
                )
                findings += gitHubFindings(report, project: project.id)
            }
        }
        return findings
    }

    /// The Repos a token must be able to publish: every declared Repo except the `spec` role.
    private func workingRepos(of project: ProjectConfiguration) -> [(name: String, path: String)] {
        let home = homeDirectory.path(percentEncoded: false)
        return project.repos.filter { $0.role != .spec }.map {
            (name: $0.name, path: Doctor.expandTilde($0.path, homeDirectory: home))
        }
    }

    /// One read of the Keychain item: a miss is told from a locked Keychain by asking for presence.
    private func lookUpSecret(_ reference: CredentialReference) -> GitHubCredentialValidation.SecretLookup {
        if let token = credentials.secret(for: reference) { return .present(token) }
        switch credentials.presence(of: reference) {
        case .absent: return .absent
        case .unreadable(let detail): return .unreadable(detail)
        case .present: return .unreadable("the item could not be read")
        }
    }

    private func gitHubFindings(_ report: GitHubCredentialReport, project: ProjectID) -> [DoctorFinding] {
        let prefix = "Project \(project.rawValue): " // glossary:ignore GL001
        var findings = [finding(
            .github, subject: "credential", credentialSeverity(report.state), prefix + report.message,
            project: project
        )]
        for repo in report.repos {
            findings.append(finding(
                .github, subject: "repo \(repo.name)", repoSeverity(repo.status), prefix + repo.message,
                project: project
            ))
        }
        return findings
    }

    private func defaultReferenceFinding(_ report: GitHubCredentialReport) -> DoctorFinding {
        switch report.state {
        case .resolves, .missing:
            finding(
                .github, subject: "credential", .info, "\(report.message) No Project uses it yet."
            )
        case .unreadable, .rejected, .unreachable:
            finding(.github, subject: "credential", credentialSeverity(report.state), report.message)
        }
    }

    private func credentialSeverity(_ state: GitHubCredentialReport.State) -> DoctorSeverity {
        switch state {
        case .resolves: .pass
        case .missing, .unreadable, .rejected: .failure
        case .unreachable: .warning
        }
    }

    private func repoSeverity(_ status: GitHubCredentialReport.RepoStatus) -> DoctorSeverity {
        switch status {
        case .ok, .okUnverified: .pass
        case .unreachable: .warning
        case .noPushPermission, .missingScope, .notFound, .notGitHub, .rejected: .failure
        }
    }
}
