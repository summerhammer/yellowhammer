import Config
import Domain
import Foundation

extension Doctor {
    /// Check 5 (shift-scheduling/diagnose-the-installation): Code Hosting Connections (`github`).
    /// Runs once per Code Hosting Connection in the registry, in registry order. Each connection reports its
    /// local name, its type, its live Code Hosting identity (for GitHub, the login), and the Projects that select
    /// it. A refused connection fails ([FAIL]) naming the connection, the Projects it serves, and the fix.
    ///
    /// An unreferenced connection (no Project names it) is reported as context (info).
    ///
    /// If the connection resolves, the push check runs per Project and per working Repo (spec-role Repos
    /// are skipped; unverifiable fine-grained tokens are reported as unverified passes).
    ///
    /// A Project naming a connection not in the registry fails ([FAIL]) for that Project, naming the Project
    /// and the missing name.
    func runGitHubCheck(configuration: Configuration) async -> [DoctorFinding] {
        let connections = configuration.machine.codeHostingConnections
        let missing = missingConnectionFindings(configuration: configuration)
        guard !connections.isEmpty else {
            guard configuration.projects.isEmpty, missing.isEmpty else { return missing }
            return [finding(
                .github, subject: "credential", .info,
                "No Code Hosting Connection is connected; connect one with "
                    + "`yh config connect-code-hosting github --token-stdin`."
            )]
        }

        var findings: [DoctorFinding] = []
        for connection in connections {
            let served = configuration.projects.filter { $0.codeHostingConnectionName == connection.name }
            findings += await connectionFindings(connection, serving: served)
        }
        return findings + missing
    }

    private func connectionFindings(
        _ connection: CodeHostingConnection, serving served: [ProjectConfiguration]
    ) async -> [DoctorFinding] {
        let servedSorted = served.sorted { $0.id.rawValue < $1.id.rawValue }
        let servedIDs = servedSorted.map(\.id)
        let scope = DoctorCodeHostingScope(name: connection.name, projects: servedIDs)
        let typeName = switch connection.kind {
        case .githubCLI: "gh"
        case .keychainToken: "keychain"
        }

        if let projectFilter, !served.isEmpty, !served.contains(where: { $0.id == projectFilter }) {
            return []
        }

        switch connection.kind {
        case .githubCLI:
            return [cliConnectionFinding(scope, type: typeName)]

        case .keychainToken(let reference):
            return await keychainConnectionFindings(
                connection: connection, reference: reference, scope: scope,
                type: typeName, served: servedSorted
            )
        }
    }

    private func cliConnectionFinding(
        _ scope: DoctorCodeHostingScope, type: String
    ) -> DoctorFinding {
        let prefix = Self.connectionPrefix(scope, type: type, login: nil)
        let refusal = CodeHostingRefusal.githubCLINotSupported(connection: scope.name)
        if scope.projects.isEmpty {
            return finding(
                .github, subject: "credential", .info,
                prefix + "\(refusal.description) No Project uses it yet.",
                codeHosting: scope
            )
        }
        return finding(
            .github, subject: "credential", .failure,
            prefix + "\(refusal.description) Select a Keychain token connection instead in Settings › Code Hosting, "
                + "or connect one under a different name and select it in the Project file.",
            codeHosting: scope
        )
    }

    private func keychainConnectionFindings(
        connection: CodeHostingConnection, reference: CredentialReference,
        scope: DoctorCodeHostingScope, type: String, served: [ProjectConfiguration]
    ) async -> [DoctorFinding] {
        let secret = credentials.gitHubSecret(for: reference)
        if served.isEmpty {
            let report = await gitHub.report(
                reference: reference, secret: secret, repos: [], connectionName: connection.name
            )
            return [unreferencedFinding(report, scope: scope, type: type, reference: reference)]
        }

        let activeProjects = served.filter { projectFilter == nil || $0.id == projectFilter }
        let allRepos = activeProjects.flatMap { workingRepos(of: $0) }
        let report = await gitHub.report(
            reference: reference, secret: secret, repos: allRepos, connectionName: connection.name
        )

        var findings = [
            connectionFinding(report, scope: scope, type: type, reference: reference)
        ]
        guard report.state == .resolves else { return findings }

        for project in activeProjects {
            let projectRepos = workingRepos(of: project)
            for repo in projectRepos {
                guard let result = report.repos.first(where: { $0.path == repo.path && $0.name == repo.name }) else {
                    continue
                }
                let repoPrefix = Self.repoPrefix(project.id, connection: connection.name)
                findings.append(finding(
                    .github, subject: "repo \(repo.name)", repoSeverity(result.status),
                    repoPrefix + result.message,
                    project: project.id,
                    codeHosting: DoctorCodeHostingScope(name: connection.name, projects: [project.id])
                ))
            }
        }
        return findings
    }

    private func connectionFinding(
        _ report: GitHubCredentialReport, scope: DoctorCodeHostingScope, type: String,
        reference: CredentialReference
    ) -> DoctorFinding {
        let prefix = Self.connectionPrefix(scope, type: type, login: report.login)
        switch report.state {
        case .resolves:
            return finding(.github, subject: "credential", .pass, prefix + report.message, codeHosting: scope)
        case .unreachable:
            return finding(.github, subject: "credential", .warning, prefix + report.message, codeHosting: scope)
        case .missing:
            let detail = "no GitHub token found under reference \(reference.rawValue) in Keychain; "
                + "replace it in Settings › Code Hosting or run "
                + "`yh config replace-code-hosting-token \(scope.name) --token-stdin`"
            return finding(.github, subject: "credential", .failure, prefix + detail, codeHosting: scope)
        case .unreadable:
            let detail = "the Keychain item for \(reference.rawValue) could not be read; "
                + "unlock the login Keychain, reconnect in Settings › Code Hosting, or replace it with "
                + "`yh config replace-code-hosting-token \(scope.name) --token-stdin`"
            return finding(.github, subject: "credential", .failure, prefix + detail, codeHosting: scope)
        case .rejected:
            let detail = "GitHub rejected the token in \(reference.rawValue): it is wrong, revoked or expired; "
                + "replace it in Settings › Code Hosting or run "
                + "`yh config replace-code-hosting-token \(scope.name) --token-stdin`"
            return finding(.github, subject: "credential", .failure, prefix + detail, codeHosting: scope)
        }
    }

    private func unreferencedFinding(
        _ report: GitHubCredentialReport, scope: DoctorCodeHostingScope, type: String,
        reference: CredentialReference
    ) -> DoctorFinding {
        let prefix = Self.connectionPrefix(scope, type: type, login: report.login)
        switch report.state {
        case .resolves:
            return finding(
                .github, subject: "credential", .info,
                prefix + "\(report.message) No Project uses it yet.",
                codeHosting: scope
            )
        case .missing:
            return finding(
                .github, subject: "credential", .info,
                prefix + "no GitHub token found under reference \(reference.rawValue) in Keychain. "
                    + "No Project uses it yet.",
                codeHosting: scope
            )
        case .unreadable, .rejected, .unreachable:
            return finding(
                .github, subject: "credential", .info,
                prefix + "\(report.message) No Project uses it yet.",
                codeHosting: scope
            )
        }
    }

    /// `Code Hosting Connection github (type "keychain"; login "octocat"; Projects alpha, beta): `
    static func connectionPrefix(
        _ scope: DoctorCodeHostingScope, type: String, login: String?
    ) -> String {
        var parts: [String] = ["type \"\(type)\""]
        if let login {
            parts.append("login \"\(login)\"")
        }
        let projectList = scope.projects.map(\.rawValue).joined(separator: ", ")
        parts.append(scope.projects.isEmpty ? "no Projects" : "Projects " + projectList)
        return "Code Hosting Connection \(scope.name) (\(parts.joined(separator: "; "))): "
    }

    static func repoPrefix(_ id: ProjectID, connection: String) -> String {
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
                    + "connect it with `yh config connect-code-hosting \(name) --token-stdin`, "
                    + "or select another connection under [code_hosting] in the Project file",
                project: id,
                codeHosting: DoctorCodeHostingScope(name: name, projects: [id])
            )
        }
    }

    /// The Repos a token must be able to publish: every declared Repo except the `spec` role.
    private func workingRepos(of project: ProjectConfiguration) -> [(name: String, path: String)] {
        let home = homeDirectory.path(percentEncoded: false)
        return project.repos.filter { $0.role != .spec }.map {
            (name: $0.name, path: Doctor.expandTilde($0.path, homeDirectory: home))
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
