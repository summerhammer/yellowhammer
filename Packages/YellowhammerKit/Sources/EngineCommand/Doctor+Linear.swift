import Config
import Domain
import Engine

extension Doctor {
    /// Check 4 (shift-scheduling/diagnose-the-installation): the Installation's own token pair, then
    /// authorization, then the Operator identity (Operator Identity Ruling, OQ66: a stale Operator
    /// identity is flagged, never a load-time failure).
    func runLinearCheck(machine: MachineConfiguration) async -> [DoctorFinding] {
        guard !machine.linearInstallations.isEmpty else {
            return [finding(
                .linear, subject: "installation", .failure,
                "no Linear App Installation is configured; run the Linear step: " +
                    "yh setup --install-linear, or the Setup view in Yellowhammer.app"
            )]
        }
        guard let sole = machine.soleLinearInstallation else {
            return [finding(
                .linear, subject: "installation", .failure,
                "config.toml declares \(machine.linearInstallations.count) Linear App Installations; "
                    + "this version of yh doctor checks exactly one"
            )]
        }
        guard credentials.secret(for: sole.credential) != nil else {
            return [finding(
                .linear, subject: "installation", .failure,
                "no Linear Installation token pair found; re-run the Linear step: " +
                    "yh setup --install-linear, or the Setup view in Yellowhammer.app"
            )]
        }

        let members: [BoardMember]
        do {
            let board = bindProvisioning(sole, "")
            members = try await board.workspaceMembers()
        } catch .notAuthenticated {
            return [finding(
                .linear, subject: "authorization", .failure,
                "the Linear installation was revoked or its sign-in expired; re-run the Linear step: " +
                    "yh setup --install-linear, or the Setup view in Yellowhammer.app"
            )]
        } catch .unreachable {
            return [finding(.linear, subject: "authorization", .failure, "Linear could not be reached")]
        } catch {
            return [finding(.linear, subject: "authorization", .failure, "Linear authorization failed: \(error)")]
        }

        var findings = [finding(.linear, subject: "authorization", .pass, "Linear authorization succeeded")]
        findings.append(operatorIdentityFinding(installation: sole, members: members))
        return findings
    }

    private func operatorIdentityFinding(installation: LinearInstallation, members: [BoardMember]) -> DoctorFinding {
        guard let configured = installation.operatorIdentity else {
            return finding(
                .linear, subject: "operator", .warning,
                "no Operator identity configured; Waiting on You issues will be left " // glossary:ignore GL001
                    + "unassigned; run `yh config operator`"
            )
        }
        let candidates = OperatorIdentity.candidates(from: members)
        guard candidates.contains(where: { $0.id == configured }) else {
            return finding(
                .linear, subject: "operator", .warning,
                "the configured Operator identity \(configured.rawValue) is no longer a " // glossary:ignore GL001
                    + "candidate (deactivated, removed, or an app)"
            )
        }
        return finding(.linear, subject: "operator", .pass, "Operator identity \(configured.rawValue) is a candidate")
    }
}
