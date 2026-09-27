import Config
import Domain

extension Setup {
    /// The Linear step, for now (P17.6 replaces this with the browser install): requires an
    /// Installation token pair to already exist in the Keychain. Setup never creates one itself in this
    /// slice — only checks for it and, once present, proceeds to authorize as today.
    func bindWorkspaceBoard(machine: MachineConfiguration) throws -> any BoardProvisioning {
        guard credentials.secret(for: machine.linearCredential) != nil else {
            throw SetupError(
                "Yellowhammer is not installed in a Linear workspace yet; run the Linear step of yh setup"
            )
        }
        return bindProvisioning(machine, "")
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
