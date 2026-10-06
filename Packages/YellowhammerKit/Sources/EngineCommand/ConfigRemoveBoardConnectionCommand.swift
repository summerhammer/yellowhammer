import ArgumentParser
import Config
import Domain
import Foundation

/// `yh config remove-board-connection <name>`: removes one Board Connection from the machine registry and
/// deletes its Keychain items (spec `install-the-linear-app`, *Removing a connection*; OQ109 item 14;
/// OQ116). No confirmation prompt by default: the refusals are the guard, and the app runs it
/// non-interactively.
///
/// `--orphan-projects` (OQ121) is the one override: it removes the Board Connection even while Project files
/// still name it, but only when its authorization is permanently refused (the Keychain item is absent, or
/// Linear refused it) — otherwise a Feature in flight and a dead connection deadlock `yh project remove`.
/// It asks for confirmation unless `--yes`. Those Projects then name a missing connection, and
/// `yh project remove` removes them.
public struct ConfigRemoveBoardConnectionCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "remove-board-connection",
        abstract: "Remove a Board Connection from config.toml and delete its Keychain items.",
        discussion: "With --orphan-projects, removes it even while Projects name it, but only when its "
            + "authorization is permanently refused."
    )

    @Argument(help: "The local name of the Board Connection to remove.")
    public var name: String

    @Flag(
        name: .customLong("orphan-projects"),
        help: "Remove the Board Connection even while Projects name it, when its authorization is refused."
    )
    public var orphanProjects: Bool = false

    @Flag(help: "With --orphan-projects, remove without asking for confirmation.")
    public var yes: Bool = false

    public init() {}

    public func validate() throws {
        guard !yes || orphanProjects else {
            throw ValidationError("--yes requires --orphan-projects")
        }
    }

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await run(
            configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory),
            homeDirectory: homeDirectory
        )
    }

    func run(
        configurationDirectory: URL,
        homeDirectory: URL,
        output: @escaping (String) -> Void = { print($0) },
        credentials: any InstallationCredentialDeleter = KeychainInstallationCredentialDeleter(),
        presence: any SetupCredentialStore = KeychainSetupCredentialStore(),
        bindProvisioning: @escaping (LinearInstallation, String) -> any BoardProvisioning = {
            BoardBinding.provisioning(installation: $0, linearProjectID: $1)
        },
        console: any SetupConsole = RealSetupConsole()
    ) async throws {
        let removal = InstallationRemoval(
            configurationDirectory: configurationDirectory, homeDirectory: homeDirectory,
            output: output, credentials: credentials,
            probe: InstallationAuthorizationProbe(credentials: presence, bindProvisioning: bindProvisioning),
            console: console, orphanProjects: orphanProjects, assumeYes: yes
        )
        switch await removal.run(name: name) {
        case .removed:
            return
        case .refused:
            throw ExitCode(1)
        case .usage(let message):
            throw ValidationError(message)
        }
    }
}

/// How an ``InstallationRemoval`` ended.
enum RemovalOutcome: Equatable {
    case removed
    /// Not removed; the reason was printed. Exit code 1.
    case refused
    /// A usage error (exit code 64): the invocation itself was wrong.
    case usage(String)
}

/// `yh config remove-board-connection`'s orchestration, with every side effect injected as a seam.
///
/// Keychain first, then `config.toml`, on purpose: a failure after the Keychain step leaves an entry with
/// no tokens, which `yh doctor` reports; the reverse order would orphan a secret. The installation's
/// `.lock` file is left alone.
///
/// The order inside `run` is the contract: lenient load and name check; undecodable Project files; with
/// `--orphan-projects`, the usage check (from files alone, before any Keychain or live call), then the
/// authorization probe, then the confirmation; only then the deletions.
struct InstallationRemoval {
    let configurationDirectory: URL
    let homeDirectory: URL
    let output: (String) -> Void
    let credentials: any InstallationCredentialDeleter
    let probe: InstallationAuthorizationProbe
    let console: any SetupConsole
    let orphanProjects: Bool
    let assumeYes: Bool

    var machineFileURL: URL {
        configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory)
    }

    func run(name: String) async -> RemovalOutcome {
        do {
            // The removal-shaped load: a Project naming a missing connection still loads.
            let configuration = try Configuration.loadLeniently(directory: configurationDirectory)
            guard let installation = configuration.machine.linearInstallation(named: name) else {
                let names = configuration.machine.linearInstallations.map(\.name)
                let valid = names.isEmpty ? "none configured" : names.joined(separator: ", ")
                throw SetupError("no Board Connection is named \"\(name)\"; valid names: \(valid)")
            }
            let named = configuration.projects.filter { $0.linearInstallationName == name }
                .map(\.id.rawValue).sorted()
            if orphanProjects {
                if let usage = try await orphan(installation, named: named, configuration: configuration) {
                    return usage
                }
            } else {
                try refuseWhileReferenced(name: name, named: named, configuration: configuration)
            }
            try deleteCredential(of: installation)
            try removeEntry(named: name)
            output("Board Connection \(name) removed: its entry in config.toml and its Keychain items.")
            if orphanProjects {
                Self.orphanReport(name: name, named: named).forEach(output)
            } else {
                output(
                    "Yellowhammer stays installed in that Linear workspace until a workspace admin removes it "
                        + "in Linear's settings."
                )
            }
            return .removed
        } catch {
            output("\(error)")
            return .refused
        }
    }

    /// The `--orphan-projects` gates. Nil to proceed to the deletions; a usage outcome for a wrong
    /// invocation; throws a refusal otherwise (including a declined confirmation).
    private func orphan(
        _ installation: LinearInstallation, named: [String], configuration: Configuration
    ) async throws -> RemovalOutcome? {
        let name = installation.name
        let files = configuration.invalidProjects.map(\.file).sorted()
        if !files.isEmpty {
            throw SetupError("Board Connection \"\(name)\" was not removed: " + Self.undecodableRefusal(name, files))
        }
        guard !named.isEmpty else {
            return .usage(
                "no Project names Board Connection \"\(name)\", so there is nothing to orphan; "
                    + "`yh config remove-board-connection \(name)` removes it"
            )
        }
        let authorization = await probe.check(installation).authorization
        if let refusal = Self.orphanRefusal(authorization, name: name, named: named) {
            throw SetupError(refusal)
        }
        if !assumeYes {
            output("Board Connection \(name) is permanently refused, but Projects still name it:")
            Self.orphanReport(name: name, named: named).forEach(output)
            let answer = console.ask("Remove Board Connection \(name) anyway? [y/N] ")?
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard let answer, ["y", "yes"].contains(answer) else {
                throw SetupError("Board Connection \"\(name)\" was not removed: not confirmed")
            }
        }
        return nil
    }

    /// The message for an authorization that does not unlock the override; nil when it is `.refused`.
    private static func orphanRefusal(
        _ authorization: InstallationAuthorization, name: String, named: [String]
    ) -> String? {
        let prefix = "Board Connection \"\(name)\" was not removed: "
        switch authorization {
        case .refused:
            return nil
        case .authorized:
            return prefix + "its authorization is healthy (authorized); remove the Projects first: "
                + named.map { "yh project remove \($0)" }.joined(separator: "; ") // glossary:ignore GL001
        case .unreachable(.keychainUnreadable(let detail)):
            return prefix + "its Keychain item could not be read (\(detail)), so its authorization cannot "
                + "be judged (keychain unreadable); unlock the Keychain and retry"
        case .unreachable(.linearUnreachable):
            return prefix + "Linear could not be reached, so its authorization cannot be judged "
                + "(Linear unreachable); retry when Linear is reachable"
        case .unreachable(.unconfirmed(let detail)):
            return prefix + "Linear's answer could not be confirmed as a refusal (\(detail)) "
                + "(could not confirm); retry"
        }
    }

    /// (a)–(e): the connection, the Projects it leaves refused, the next step for each, that Yellowhammer
    /// stays installed in the Linear workspace, and the undo.
    static func orphanReport(name: String, named: [String]) -> [String] {
        [
            "Board Connection \(name) (its entry in config.toml and its Keychain items).",
            "Projects naming it, each refused at load until removed or re-connected: "
                + named.joined(separator: ", "),
            "Next step: " + named.map { "yh project remove \($0)" }.joined(separator: "; "), // glossary:ignore GL001
            "Yellowhammer stays installed in that Linear workspace until a workspace admin removes it "
                + "in Linear's settings.",
            "Undo: `yh setup --board-connection-name \(name)` re-connects it under this exact "
                + "local name and brings the Projects back."
        ]
    }

    private static func undecodableRefusal(_ name: String, _ files: [String]) -> String {
        "these Project files failed to decode, so whether they name Board Connection \"\(name)\" cannot be "
            + "known; fix or remove them first:\n" + files.map { "  \($0)" }.joined(separator: "\n")
    }

    private func refuseWhileReferenced(name: String, named: [String], configuration: Configuration) throws {
        var refusals: [String] = []
        if !named.isEmpty {
            let plural = named.count != 1
            refusals.append(
                "Project\(plural ? "s" : "") \(named.joined(separator: ", ")) use\(plural ? "" : "s") "
                    + "Board Connection \"\(name)\"; remove \(plural ? "them" : "it") first: "
                    + named.map { "yh project remove \($0)" }.joined(separator: "; ") // glossary:ignore GL001
                    + "; if its authorization can never be restored, add --orphan-projects"
            )
        }
        let files = configuration.invalidProjects.map(\.file).sorted()
        if !files.isEmpty {
            refusals.append(Self.undecodableRefusal(name, files))
        }
        guard refusals.isEmpty else {
            throw SetupError("Board Connection \"\(name)\" was not removed: " + refusals.joined(separator: "\n"))
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
            throw SetupError("could not remove the Board Connection: \(error)")
        }
        do {
            try updated.write(to: machineFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw SetupError("could not write \(path): \(error)")
        }
    }
}
