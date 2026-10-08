import Config
import Domain
import Foundation

extension Doctor {
    /// Check: the GitHub credential. Each valid Project's Code Hosting Connection is resolved through the one
    /// resolver. A refusal (a connection that cannot give a credential) is one `credential` failure for that
    /// Project, naming the connection. The rest are grouped by connection and the token is read once per
    /// connection; each Project then gets one `credential` finding and one finding per working Repo (a Repo
    /// whose role is `spec` is skipped: the Spec Source is read-only, so nothing is pushed to it). Every
    /// finding is scoped to its Project. A refused Project whose connection is missing from the registry gets
    /// a `project` failure naming both fixes.
    ///
    /// With no valid Project there is nothing to publish yet, so every connection in the registry is checked
    /// on its own and reported as context (`info`) when it resolves or is absent; an empty registry says how
    /// to connect one.
    func runGitHubCheck(configuration: Configuration) async -> [DoctorFinding] {
        let missing = missingConnectionFindings(configuration: configuration)
        guard !configuration.projects.isEmpty else {
            return await registryFindings(configuration: configuration, hasRefusedProjects: !missing.isEmpty) + missing
        }

        let selected = configuration.projects.filter { projectFilter == nil || $0.id == projectFilter }
        var groups: [ConnectionGroup] = []
        var findings: [DoctorFinding] = []
        for entry in selected {
            do {
                let credential = try configuration.machine.codeHostingCredential(for: entry)
                if let index = groups.firstIndex(where: { $0.connection == credential.connection }) {
                    groups[index].projects.append(entry)
                } else {
                    groups.append(ConnectionGroup(
                        connection: credential.connection, reference: credential.reference, projects: [entry]
                    ))
                }
            } catch {
                findings.append(finding(
                    .github, subject: "credential", .failure,
                    Self.prefix(entry.id, connection: entry.codeHostingConnectionName) + error.description,
                    project: entry.id
                ))
            }
        }

        for group in groups {
            let secret = credentials.gitHubSecret(for: group.reference)
            for entry in group.projects {
                let report = await gitHub.report(
                    reference: group.reference, secret: secret, repos: workingRepos(of: entry)
                )
                findings += gitHubFindings(report, id: entry.id, connection: group.connection)
            }
        }
        return findings + missing
    }

    /// The valid Projects that select one connection, and the Keychain reference it resolved to.
    private struct ConnectionGroup {
        let connection: String
        let reference: CredentialReference
        var projects: [ProjectConfiguration]
    }

    private static func prefix(_ id: ProjectID, connection: String) -> String {
        "Project \(id.rawValue) (Code Hosting Connection \(connection)): " // glossary:ignore GL001
    }

    /// One failure per refused Project whose `[code_hosting] connection` names no registry entry, in Project
    /// id order.
    private func missingConnectionFindings(configuration: Configuration) -> [DoctorFinding] {
        var refused: [(id: ProjectID, name: String)] = []
        for invalid in configuration.invalidProjects {
            guard let id = projectID(forInvalid: invalid) else { continue }
            for error in invalid.errors {
                if case .undeclaredCodeHostingConnection(let name) = error.reason {
                    refused.append((id, name))
                }
            }
        }
        return refused.sorted { $0.id.rawValue < $1.id.rawValue }.map { id, name in
            let named = "Project \(id) names Code Hosting Connection \(name)" // glossary:ignore GL001
            return finding(
                .github, subject: "project", .failure, // glossary:ignore GL001
                named + ", which is not in the registry; "
                    + "connect it with `yh setup --install-github --code-hosting-connection \(name)`, "
                    + "or select another connection under [code_hosting] in the Project file",
                project: id
            )
        }
    }

    /// With no valid Project: each registry connection, credential-only. A `gh` CLI connection cannot be used by
    /// this build yet, which is context rather than a fault while no Project selects it.
    private func registryFindings(configuration: Configuration, hasRefusedProjects: Bool) async -> [DoctorFinding] {
        let connections = configuration.machine.codeHostingConnections
        guard !connections.isEmpty else {
            guard !hasRefusedProjects else { return [] }
            return [finding(
                .github, subject: "credential", .info,
                "No Code Hosting Connection is connected; connect one with `yh setup --install-github`."
            )]
        }
        var findings: [DoctorFinding] = []
        for connection in connections {
            do {
                let credential = try configuration.machine.codeHostingCredential(connectionNamed: connection.name)
                let report = await gitHub.report(
                    reference: credential.reference, secret: credentials.gitHubSecret(for: credential.reference),
                    repos: []
                )
                findings.append(registryFinding(report, connection: connection.name))
            } catch {
                findings.append(finding(
                    .github, subject: "credential", .info,
                    "Code Hosting Connection \(connection.name): \(error.description) No Project uses it yet."
                ))
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

    private func gitHubFindings(
        _ report: GitHubCredentialReport, id: ProjectID, connection: String
    ) -> [DoctorFinding] {
        let prefix = Self.prefix(id, connection: connection)
        var findings = [finding(
            .github, subject: "credential", credentialSeverity(report.state), prefix + report.message,
            project: id
        )]
        for repo in report.repos {
            findings.append(finding(
                .github, subject: "repo \(repo.name)", repoSeverity(repo.status), prefix + repo.message,
                project: id
            ))
        }
        return findings
    }

    private func registryFinding(_ report: GitHubCredentialReport, connection: String) -> DoctorFinding {
        let prefix = "Code Hosting Connection \(connection): "
        switch report.state {
        case .resolves, .missing:
            return finding(.github, subject: "credential", .info, "\(prefix)\(report.message) No Project uses it yet.")
        case .unreadable, .rejected, .unreachable:
            return finding(.github, subject: "credential", credentialSeverity(report.state), prefix + report.message)
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
