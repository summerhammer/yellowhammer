import ArgumentParser
import Config
import Domain
import Engine
import Foundation

/// `yh config operator [--installation <name>] <user-id>`: changes one App Installation's Operator
/// identity, the `operator` key of its `[board.linear.installations.<name>]` table (spec
/// `install-the-linear-app`; OQ66; OQ109 items 7 and 8; OQ116).
public struct ConfigOperatorCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "operator",
        abstract: "Change an App Installation's Operator identity."
    )

    @Option(
        name: .customLong("installation"),
        help: "The local name of the Linear App Installation; optional when exactly one is configured."
    )
    public var installation: String?

    @Argument(help: "The Linear user id of the new Operator identity.")
    public var userID: String

    public init() {}

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(
        configurationDirectory: URL,
        output: @escaping (String) -> Void = { print($0) },
        bindProvisioning: @escaping (LinearInstallation, String) -> any BoardProvisioning = { installation, project in
            BoardBinding.provisioning(installation: installation, linearProjectID: project)
        }
    ) async throws {
        let change = ConfigOperatorChange(
            configurationDirectory: configurationDirectory, output: output, bindProvisioning: bindProvisioning
        )
        guard await change.run(installation: installation, userID: userID) else {
            throw ExitCode(1)
        }
    }
}

/// `yh config operator`'s orchestration, with every side effect injected as a seam, mirroring
/// ``ProjectRemoval``. Validates against the installation's own workspace members, then writes only that
/// installation's table.
struct ConfigOperatorChange {
    let configurationDirectory: URL
    let output: (String) -> Void
    let bindProvisioning: (LinearInstallation, String) -> any BoardProvisioning

    var machineFileURL: URL {
        configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory)
    }

    /// Returns whether the change succeeded, the command's exit code. Every refusal writes nothing.
    func run(installation requested: String?, userID: String) async -> Bool {
        do {
            let machine = try MachineConfiguration.load(contentsOf: machineFileURL)
            let installation = try resolve(requested, in: machine)
            let members = try await workspaceMembers(of: installation)
            let id = BoardObjectID(rawValue: userID)
            guard OperatorIdentity.candidates(from: members).contains(where: { $0.id == id }) else {
                throw SetupError(OperatorIdentityEditing.exclusionMessage(id: id, members: members))
            }
            if installation.operatorIdentity != id {
                try OperatorIdentityEditing.write(id, installation: installation.name, machineFileURL: machineFileURL)
            }
            output("Installation \(installation.name): Operator identity is now \(id.rawValue)")
            // The change is forward-only (OQ66 item 4): it never reassigns what is already assigned.
            output(
                "The change applies from the next Act; it does not reassign issues already in " // glossary:ignore GL001
                    + "Waiting on You." // glossary:ignore GL001
            )
            return true
        } catch {
            output("\(error)")
            return false
        }
    }

    private func resolve(_ requested: String?, in machine: MachineConfiguration) throws -> LinearInstallation {
        let names = machine.linearInstallations.map(\.name)
        guard !names.isEmpty else {
            throw SetupError(
                "no Linear App Installation is configured; connect a Linear workspace first: "
                    + "yh setup --install-linear"
            )
        }
        if let requested {
            guard let installation = machine.linearInstallation(named: requested) else {
                throw SetupError(
                    "no Linear App Installation is named \"\(requested)\"; "
                        + "valid names: \(names.joined(separator: ", "))"
                )
            }
            return installation
        }
        guard machine.linearInstallations.count == 1 else {
            throw SetupError(
                "config.toml declares \(names.count) Linear App Installations (\(names.joined(separator: ", "))); "
                    + "--installation is required"
            )
        }
        return machine.linearInstallations[0]
    }

    private func workspaceMembers(of installation: LinearInstallation) async throws -> [BoardMember] {
        do {
            return try await bindProvisioning(installation, "").workspaceMembers()
        } catch .notAuthenticated {
            throw SetupError(
                "the Linear installation \"\(installation.name)\" was revoked or its sign-in expired; "
                    + "re-connect that workspace: yh setup --install-linear --installation \(installation.name)"
            )
        } catch .unreachable {
            throw SetupError("Linear could not be reached")
        } catch {
            throw SetupError("Linear authorization failed: \(error)")
        }
    }
}
