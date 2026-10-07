import Config
import Domain
import Engine

extension Doctor {
    /// Check 4 (shift-scheduling/diagnose-the-installation): runs once per Board Connection in the
    /// registry, in registry order. Each installation gets its token pair check, authorization and Operator
    /// identity (Operator Identity Ruling, OQ66: a stale Operator identity is flagged, never a load-time
    /// failure), an info line when no Project uses it, and then board membership for each Project it serves.
    ///
    /// A Project naming an installation that is not in the registry is refused by the strict configuration
    /// load, and Check 1 reports that; Check 4 reports it too, as a missing installation, so that
    /// `--check linear` sees it.
    func runLinearCheck(configuration: Configuration) async -> [DoctorFinding] {
        let installations = configuration.machine.linearInstallations
        let missing = missingInstallationFindings(configuration: configuration)
        guard !installations.isEmpty else {
            guard configuration.projects.isEmpty, missing.isEmpty else { return missing }
            return [finding(
                .linear, subject: "connection", .info,
                "no Linear workspace is connected; connect one with `yh setup --install-linear`, " +
                    "or Settings → Board connections in Yellowhammer.app"
            )]
        }
        var findings: [DoctorFinding] = []
        for installation in installations {
            let served = configuration.projects.filter { $0.linearInstallationName == installation.name }
            findings += await installationFindings(installation, serving: served)
        }
        return findings + missing
    }

    /// One failure per refused Project whose `installation` names no registry entry, in Project id order.
    private func missingInstallationFindings(configuration: Configuration) -> [DoctorFinding] {
        var refused: [(id: ProjectID, name: String)] = []
        for invalid in configuration.invalidProjects {
            guard let id = projectID(forInvalid: invalid) else { continue }
            for error in invalid.errors {
                if case .undeclaredLinearInstallation(let name) = error.reason {
                    refused.append((id, name))
                }
            }
        }
        return refused.sorted { $0.id.rawValue < $1.id.rawValue }.map { id, name in
            finding(
                .linear, subject: "project", .failure,
                "Project \(id) names Board Connection \(name), which is not in the registry; " // glossary:ignore GL001
                    + "connect that workspace with `yh setup --install-linear` and enter \(name) as its local "
                    + "name, or remove the Project (`yh project remove \(id)`) and add it again",
                project: id,
                installation: DoctorInstallationScope(
                    name: name, workspace: nil, workspaceName: nil, projects: [id]
                )
            )
        }
    }

    private func installationFindings(
        _ installation: LinearInstallation, serving served: [ProjectConfiguration]
    ) async -> [DoctorFinding] {
        let projectIDs = served.map(\.id)
        func scope(_ workspaceName: String?) -> DoctorInstallationScope {
            DoctorInstallationScope(
                name: installation.name, workspace: installation.workspace.rawValue,
                workspaceName: workspaceName, projects: projectIDs
            )
        }

        let board = bindProvisioning(installation, "")
        let probe = await InstallationAuthorizationProbe(
            credentials: credentials, bindProvisioning: { _, _ in board }
        ).check(installation)
        let workspaceName = probe.askedLinear ? try? await board.workspace().name : nil
        let members = probe.members
        if let failure = authorizationFailure(probe.authorization, installation, scope(workspaceName)) {
            return [failure]
        }

        var findings = [
            linearFinding(
                scope(workspaceName), "authorization", .pass, "Linear authorization succeeded",
                authorization: .authorized
            ),
            operatorIdentityFinding(
                installation: installation, members: members, scope: scope(workspaceName)
            )
        ]
        if served.isEmpty {
            findings.append(linearFinding(
                scope(workspaceName), "connection", .info,
                "no Project uses this Board Connection; if you no longer use it, run "
                    + "`yh config remove-board-connection \(installation.name)`"
            ))
        }
        for project in served {
            let membership = await boardMembershipFindings(
                project: project, installation: installation, workspaceName: workspaceName
            )
            findings += membership
            guard membership.allSatisfy({ $0.severity == .pass }) else { continue }
            findings += await boardProvisioningFindings(
                project: project, installation: installation,
                scope: DoctorInstallationScope(
                    name: installation.name, workspace: installation.workspace.rawValue,
                    workspaceName: workspaceName, projects: [project.id]
                )
            )
        }
        return findings
    }

    /// The one failure finding for a probe result that is not `.authorized`; nil when it is.
    private func authorizationFailure(
        _ authorization: InstallationAuthorization, _ installation: LinearInstallation,
        _ scope: DoctorInstallationScope
    ) -> DoctorFinding? {
        switch authorization {
        case .authorized:
            return nil
        case .refused(.keychainAbsent):
            return linearFinding(
                scope, "connection", .failure,
                "no token pair found; re-connect this workspace: "
                    + Self.reconnectFix(installation),
                authorization: .refused
            )
        case .refused(.linearRefused):
            return linearFinding(
                scope, "authorization", .failure,
                "the Board Connection was revoked or its sign-in expired; a workspace admin must approve "
                    + "the app again: " + Self.reconnectFix(installation),
                authorization: .refused
            )
        case .unreachable(.keychainUnreadable(let detail)):
            return linearFinding(
                scope, "authorization", .failure,
                "the Keychain item of this Board Connection could not be read (\(detail)); "
                    + "unlock the login Keychain and run `yh doctor` again",
                authorization: .unreachable
            )
        case .unreachable(.linearUnreachable):
            return linearFinding(
                scope, "authorization", .failure, "Linear could not be reached", authorization: .unreachable
            )
        case .unreachable(.unconfirmed(let detail)):
            return linearFinding(
                scope, "authorization", .failure, "Linear authorization failed: \(detail)",
                authorization: .unreachable
            )
        }
    }

    private func linearFinding(
        _ scope: DoctorInstallationScope, _ subject: String, _ severity: DoctorSeverity, _ message: String,
        authorization: InstallationAuthorizationState? = nil
    ) -> DoctorFinding {
        var finding = finding(
            .linear, subject: subject, severity, Self.installationPrefix(scope) + message, installation: scope
        )
        finding.authorization = authorization
        return finding
    }

    /// `Board Connection acme (workspace "Acme Inc"; Projects alpha, beta): ` — the workspace name only when it
    /// was read live; `no Projects` when the Board Connection serves none.
    static func installationPrefix(_ scope: DoctorInstallationScope) -> String {
        var parts: [String] = []
        if let name = scope.workspaceName {
            parts.append("workspace \"\(name)\"")
        }
        let projects = scope.projects.map(\.rawValue).joined(separator: ", ")
        parts.append(scope.projects.isEmpty ? "no Projects" : "Projects " + projects)
        return "Board Connection \(scope.name) (\(parts.joined(separator: "; "))): "
    }

    static func reconnectFix(_ installation: LinearInstallation) -> String {
        "`yh setup --install-linear --board-connection \(installation.name)`, "
            + "or Settings → Board connections in Yellowhammer.app"
    }

    private func operatorIdentityFinding(
        installation: LinearInstallation, members: [BoardMember], scope: DoctorInstallationScope
    ) -> DoctorFinding {
        guard let configured = installation.operatorIdentity else {
            let served = scope.projects.isEmpty
                ? "the Projects it serves" : scope.projects.map(\.rawValue).joined(separator: ", ")
            return linearFinding(
                scope, "operator", .warning,
                "no Operator identity configured; Waiting on You issues of \(served) " // glossary:ignore GL001
                    + "will be left unassigned; run `yh config operator --board-connection \(installation.name)`"
            )
        }
        let candidates = OperatorIdentity.candidates(from: members)
        guard candidates.contains(where: { $0.id == configured }) else {
            return linearFinding(
                scope, "operator", .warning,
                "the configured Operator identity \(configured.rawValue) is no longer a " // glossary:ignore GL001
                    + "candidate (deactivated, removed, or an app)"
            )
        }
        return linearFinding(scope, "operator", .pass, "Operator identity \(configured.rawValue) is a candidate")
    }
}
