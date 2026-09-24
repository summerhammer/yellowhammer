import Config
import Domain
import Engine

extension Doctor {
    /// Check 4: the Linear client secret and authorization, then the Operator identity (Operator
    /// Identity Ruling, OQ66: a stale Operator identity is flagged, never a load-time failure).
    func runLinearCheck(machine: MachineConfiguration) async -> [DoctorFinding] {
        guard let secret = credentials.secret(for: machine.linearCredential) else {
            return [finding(.linear, subject: "credential", .failure, missingSecretMessage(machine: machine))]
        }

        let members: [BoardMember]
        do {
            let board = try bindProvisioning(machine, "", secret)
            members = try await board.workspaceMembers()
        } catch {
            return [finding(.linear, subject: "authorization", .failure, "Linear authorization failed: \(error)")]
        }

        var findings = [finding(.linear, subject: "authorization", .pass, "Linear authorization succeeded")]
        findings.append(operatorIdentityFinding(machine: machine, members: members))
        return findings
    }

    private func operatorIdentityFinding(machine: MachineConfiguration, members: [BoardMember]) -> DoctorFinding {
        guard let configured = machine.operatorIdentity else {
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

    private func missingSecretMessage(machine: MachineConfiguration) -> String {
        """
        the Linear client secret \(machine.linearCredential.rawValue) is not available. Store it: `security \
        add-generic-password -U -s \(KeychainCredentialStore.service) -a <account> -w <secret>`.
        """
    }
}
