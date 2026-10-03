import ArgumentParser
import Config
import Domain
import Foundation

/// `yh config remove-installation <name>`: removes one App Installation from the machine registry and
/// deletes its Keychain items (spec `install-the-linear-app`, *Removing an installation*; OQ109 item 14;
/// OQ116). No confirmation prompt: the refusals are the guard, and the app runs it non-interactively.
public struct ConfigRemoveInstallationCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "remove-installation",
        abstract: "Remove an App Installation from config.toml and delete its Keychain items."
    )

    @Argument(help: "The local name of the Linear App Installation to remove.")
    public var name: String

    public init() {}

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try run(
            configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory),
            homeDirectory: homeDirectory
        )
    }

    func run(
        configurationDirectory: URL,
        homeDirectory: URL,
        output: @escaping (String) -> Void = { print($0) },
        credentials: any InstallationCredentialDeleter = KeychainInstallationCredentialDeleter()
    ) throws {
        let removal = InstallationRemoval(
            configurationDirectory: configurationDirectory, homeDirectory: homeDirectory,
            output: output, credentials: credentials
        )
        guard removal.run(name: name) else {
            throw ExitCode(1)
        }
    }
}

/// `yh config remove-installation`'s orchestration, with every side effect injected as a seam.
///
/// Keychain first, then `config.toml`, on purpose: a failure after the Keychain step leaves an entry with
/// no tokens, which `yh doctor` reports; the reverse order would orphan a secret. The installation's
/// `.lock` file is left alone.
struct InstallationRemoval {
    let configurationDirectory: URL
    let homeDirectory: URL
    let output: (String) -> Void
    let credentials: any InstallationCredentialDeleter

    var machineFileURL: URL {
        configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory)
    }

    /// Returns whether the removal succeeded, the command's exit code.
    func run(name: String) -> Bool {
        do {
            // The removal-shaped load: a Project naming a missing installation still loads.
            let configuration = try Configuration.loadLeniently(directory: configurationDirectory)
            guard let installation = configuration.machine.linearInstallation(named: name) else {
                let names = configuration.machine.linearInstallations.map(\.name)
                let valid = names.isEmpty ? "none configured" : names.joined(separator: ", ")
                throw SetupError("no Linear App Installation is named \"\(name)\"; valid names: \(valid)")
            }
            try refuseWhileReferenced(name: name, configuration: configuration)
            try deleteCredential(of: installation)
            try removeEntry(named: name)
            output("Installation \(name) removed: its entry in config.toml and its Keychain items.")
            output(
                "Yellowhammer stays installed in that Linear workspace until a workspace admin removes it "
                    + "in Linear's settings."
            )
            return true
        } catch {
            output("\(error)")
            return false
        }
    }

    private func refuseWhileReferenced(name: String, configuration: Configuration) throws {
        var refusals: [String] = []
        let named = configuration.projects.filter { $0.linearInstallationName == name }.map(\.id.rawValue).sorted()
        if !named.isEmpty {
            let plural = named.count != 1
            refusals.append(
                "Project\(plural ? "s" : "") \(named.joined(separator: ", ")) use\(plural ? "" : "s") "
                    + "installation \"\(name)\"; remove \(plural ? "them" : "it") first: "
                    + named.map { "yh project remove \($0)" }.joined(separator: "; ") // glossary:ignore GL001
            )
        }
        let files = configuration.invalidProjects.map(\.file).sorted()
        if !files.isEmpty {
            refusals.append(
                "these Project files failed to decode, so whether they name installation \"\(name)\" cannot be "
                    + "known; fix or remove them first:\n" + files.map { "  \($0)" }.joined(separator: "\n")
            )
        }
        guard refusals.isEmpty else {
            throw SetupError("installation \"\(name)\" was not removed: " + refusals.joined(separator: "\n"))
        }
    }

    private func deleteCredential(of installation: LinearInstallation) throws {
        let lock = MachineLock(
            fileURL: MachineLock.defaultFileURL(homeDirectory: homeDirectory, installation: installation.name)
        )
        do {
            try lock.withLock { try credentials.delete(installation.credential) }
        } catch .bodyFailed(let inner) {
            throw SetupError("could not delete the Keychain items of \"\(installation.name)\": \(inner)")
        } catch {
            throw SetupError("could not delete the Keychain items of \"\(installation.name)\": \(error)")
        }
    }

    private func removeEntry(named name: String) throws {
        let path = machineFileURL.path(percentEncoded: false)
        let text: String
        do {
            text = try String(contentsOf: machineFileURL, encoding: .utf8)
        } catch {
            throw SetupError("could not read \(path): \(error)")
        }
        let updated = MachineConfiguration.removingLinearInstallation(named: name, inFileText: text)
        do {
            _ = try MachineConfiguration.parse(updated, file: path)
        } catch {
            throw SetupError("could not remove the installation: \(error)")
        }
        do {
            try updated.write(to: machineFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw SetupError("could not write \(path): \(error)")
        }
    }
}
