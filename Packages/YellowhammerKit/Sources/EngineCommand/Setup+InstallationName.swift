import Config
import Domain

/// `--board-connection-name` (spec ruling OQ120): the Operator names a NEW Linear Board Connection on every
/// surface. The name is checked before the browser opens, and an Operator-given name is never altered —
/// only the automatic proposal is sanitized and suffixed.
extension Setup {
    /// Refuses a given name that is not a valid local name, or that another registry entry already
    /// uses, before the admin statement is reported and before any authorization opens. No-op without
    /// `--board-connection-name`. Under `--events json` a refusal emits `.failed(.invalidInstallationName)`.
    func checkInstallationName(machine: MachineConfiguration) async throws {
        guard let name = options.installationName else { return }
        if !LinearInstallation.isValidLocalName(name) {
            try refuseInstallationName(
                "\(name) is not a valid local name: use lowercase letters, digits, - and _, "
                    + "starting with a letter or digit; nothing was changed."
            )
        }
        if let taken = machine.linearInstallations.first(where: { $0.name == name }) {
            let workspace = await workspaceLabel(of: taken)
            try refuseInstallationName(
                "\(name) is already used by the Linear workspace \(workspace); choose another name, "
                    + "or re-connect that workspace with --board-connection \(name); nothing was changed."
            )
        }
    }

    private func refuseInstallationName(_ text: String) throws {
        if options.eventsJSON {
            linearInstallEvents(.failed(reason: .invalidInstallationName, text: text))
        }
        throw SetupError(text)
    }

    /// The entry's workspace name read live, best effort; its workspace ID when that read fails.
    private func workspaceLabel(of entry: LinearInstallation) async -> String {
        if let workspace = try? await bindProvisioning(entry, "").workspace() {
            return workspace.name
        }
        return entry.workspace.rawValue
    }

    /// The local name for a workspace new to the registry: the given `--board-connection-name` (which
    /// answers the interactive prompt, so it is not shown), else `proposed`.
    func newInstallationName(proposed: String, machine: MachineConfiguration) throws -> String {
        if let given = options.installationName { return given }
        return isInteractive ? try askLocalName(proposed: proposed, machine: machine) : proposed
    }

    /// When a name was given but Linear approved a workspace already in the registry: the given name is
    /// discarded (no second entry, no rename), and the run says so, naming the existing local name.
    func reportInstallationNameDiscarded(existing: LinearInstallation) {
        guard let given = options.installationName else { return }
        let text = "\(given) was not used: this Linear workspace is already connected as "
            + "\(existing.name), which was re-connected under its own name."
        if options.eventsJSON {
            linearInstallEvents(
                .installationNameDiscarded(given: given, installation: existing.name, text: text)
            )
        } else {
            output(text)
        }
    }
}
