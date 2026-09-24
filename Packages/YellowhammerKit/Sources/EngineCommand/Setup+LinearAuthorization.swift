import Config
import Domain

extension Setup {
    /// Step 2: reads (and, with `--linear-client-secret-stdin`, first stores) the Linear client secret.
    /// Interactive mode asks for and stores it when still absent.
    func resolveLinearSecret(machine: MachineConfiguration) throws -> String {
        if options.linearClientSecretStdin {
            guard let line = readStandardInputLine(), !line.isEmpty else {
                throw SetupError("no client secret was read from standard input")
            }
            try storeLinearSecret(line, machine: machine)
        }
        if let secret = credentials.secret(for: machine.linearCredential) {
            return secret
        }
        guard isInteractive else {
            throw SetupError(missingSecretMessage(machine: machine))
        }
        guard let entered = console.askSecret("Linear client secret: "), !entered.isEmpty else {
            throw SetupError("setup was cancelled")
        }
        try storeLinearSecret(entered, machine: machine)
        guard let secret = credentials.secret(for: machine.linearCredential) else {
            throw SetupError(missingSecretMessage(machine: machine))
        }
        return secret
    }

    private func storeLinearSecret(_ secret: String, machine: MachineConfiguration) throws {
        do {
            try credentials.store(secret, for: machine.linearCredential)
        } catch {
            throw SetupError("could not store the Linear client secret: \(error)")
        }
    }

    private func missingSecretMessage(machine: MachineConfiguration) -> String {
        """
        the Linear client secret \(machine.linearCredential.rawValue) is not available. Pass \
        --linear-client-secret-stdin, or store it directly: `security add-generic-password -U -s \
        \(KeychainCredentialStore.service) -a <account> -w <secret>`.
        """
    }

    func bindWorkspaceBoard(machine: MachineConfiguration, secret: String) throws -> any BoardProvisioning {
        do {
            return try bindProvisioning(machine, "", secret)
        } catch {
            throw SetupError("Linear authorization failed: \(error)")
        }
    }

    /// `workspaceMembers()` is the authorization proof: it is the first call this Linear identity makes.
    func authorize(board: any BoardProvisioning) async throws -> [BoardMember] {
        do {
            return try await board.workspaceMembers()
        } catch {
            throw SetupError("Linear authorization failed: \(error)")
        }
    }
}
