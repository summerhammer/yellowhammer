import Config
import Domain
import Foundation
import LinearAdapter

/// The registry half of the Linear install (roadmap L2.1; ADR-005): decides, before any Keychain or file
/// write, whether a finished install re-connects a registered Linear App Installation or adds a new one.
extension Setup {
    /// The free local name for a new registry entry: the workspace URL key, suffixed `-2`, `-3`, … while
    /// another entry (necessarily another workspace) already uses it. A URL key that is not a valid local
    /// name (`^[a-z0-9][a-z0-9_-]*$`) is lowercased with every invalid run replaced by `-`, falling back
    /// to `linear`.
    static func proposedInstallationName(urlKey: String, machine: MachineConfiguration) -> String {
        let base = validInstallationName(from: urlKey)
        let taken = Set(machine.linearInstallations.map(\.name))
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    private static func validInstallationName(from urlKey: String) -> String {
        var name = ""
        var pendingDash = false
        for scalar in urlKey.lowercased().unicodeScalars {
            let allowed = LinearInstallation.isValidLocalName(name + String(Character(scalar)))
            if allowed {
                if pendingDash, !name.isEmpty { name += "-" }
                pendingDash = false
                name.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return LinearInstallation.isValidLocalName(name) ? name : "linear"
    }

    /// Interactive only: asks for the new entry's local name, offering `proposed` on an empty answer. An
    /// invalid or already-used name re-asks; EOF cancels, before anything is written.
    private func askLocalName(proposed: String, machine: MachineConfiguration) throws -> String {
        let taken = Set(machine.linearInstallations.map(\.name))
        while true {
            guard let line = console.ask("Local name for this Linear workspace [\(proposed)]: ") else {
                throw SetupError("setup was cancelled")
            }
            let answer = line.trimmingCharacters(in: .whitespaces)
            if answer.isEmpty { return proposed }
            if !LinearInstallation.isValidLocalName(answer) {
                output("\(answer) is not a valid local name: use lowercase letters, digits, - and _, "
                    + "starting with a letter or digit.")
            } else if taken.contains(answer) {
                output("\(answer) is already used by another Linear workspace; choose another name.")
            } else {
                return answer
            }
        }
    }

    /// Stores a finished install and returns the registry entry the run then uses. The decision comes
    /// first: a re-connect aimed at `target` that Linear approved in another workspace discards the
    /// tokens (nothing stored, config.toml untouched); an approved workspace already in the registry
    /// re-connects that entry (tokens under its credential, its name and Operator identity kept,
    /// `app_user` refreshed only if it changed); any other workspace becomes a new entry named from its
    /// URL key (asked for when interactive; the name is fixed once written, since the credential
    /// `keychain:linear-<name>` derives from it). Tokens are stored under that installation's lock (so a concurrent Act never reads a
    /// half-written pair).
    func storeInstalled(
        tokens: LinearInstallFlow.InstalledTokens, identity: LinearInstallFlow.InstalledIdentity,
        target: LinearInstallation?, machine: inout MachineConfiguration
    ) async throws -> LinearInstallation {
        let workspace = BoardObjectID(rawValue: identity.workspaceID)
        let appUser = BoardObjectID(rawValue: identity.appUserID)
        if let target, target.workspace != workspace {
            let text = "Linear approved the workspace \(identity.workspaceName) (\(identity.workspaceURLKey)), "
                + "not \(target.name)'s workspace; nothing was changed. To add \(identity.workspaceName), "
                + "connect another Linear workspace: yh setup --install-linear"
            if options.eventsJSON {
                linearInstallEvents(.failed(reason: .differentWorkspace, text: text))
            }
            throw SetupError(text)
        }

        var installation: LinearInstallation
        var changesFile = true
        if let existing = machine.linearInstallations.first(where: { $0.workspace == workspace }) {
            installation = existing
            changesFile = existing.appUser != appUser
            installation.appUser = appUser
        } else {
            let proposed = Self.proposedInstallationName(urlKey: identity.workspaceURLKey, machine: machine)
            let name = isInteractive ? try askLocalName(proposed: proposed, machine: machine) : proposed
            guard let credential = CredentialReference("keychain:linear-\(name)") else {
                throw SetupError("a credential reference must not be empty")
            }
            installation = LinearInstallation(
                name: name, credential: credential, workspace: workspace, appUser: appUser
            )
        }

        let pair = LinearTokenPair(
            accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt
        )
        let store = linearInstallationStore(installation)
        do {
            try await store.tokenStore.withRefreshLock {
                try store.tokenStore.write(pair)
            }
        } catch {
            throw SetupError("could not store the Installation's tokens: \(error)")
        }

        if changesFile { try writeLinearInstallation(installation) }
        if let index = machine.linearInstallations.firstIndex(where: { $0.name == installation.name }) {
            machine.linearInstallations[index] = installation
        } else {
            machine.linearInstallations.append(installation)
        }

        let text = "Yellowhammer is installed in the Linear workspace \(identity.workspaceName) "
            + "(as \(installation.name))."
        report(.installed(workspaceName: identity.workspaceName, installation: installation.name), text: text)
        return installation
    }

    private func writeLinearInstallation(_ installation: LinearInstallation) throws {
        let path = machineFileURL.path(percentEncoded: false)
        let text: String
        do {
            text = try String(contentsOf: machineFileURL, encoding: .utf8)
        } catch {
            throw SetupError("could not read \(path): \(error)")
        }
        let updated = MachineConfiguration.settingLinearInstallation(installation, inFileText: text)
        do {
            _ = try MachineConfiguration.parse(updated, file: path)
        } catch {
            throw SetupError("could not set the Linear Installation: \(error)")
        }
        do {
            try updated.write(to: machineFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw SetupError("could not write \(path): \(error)")
        }
    }
}
