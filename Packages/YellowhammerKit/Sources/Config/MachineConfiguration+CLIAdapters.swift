import Domain
import Foundation

extension MachineConfiguration {
    /// The GitHub credential reference a new machine file starts with, unless `yh setup` is given another.
    public static let defaultGitHubCredential = "keychain:github"

    /// A machine file that does not exist yet: the default GitHub credential and nothing declared. What the
    /// app declares the first agent CLI against on a fresh Mac, before any Linear Board Connection exists.
    public static var unconfigured: MachineConfiguration {
        // Non-empty literal: never fails.
        MachineConfiguration(
            gitHubCredential: CredentialReference(defaultGitHubCredential)!, cliAdapters: [], routingTable: []
        )
    }

    /// The registered CLI Adapter names (``RegisteredCLIAdapters``) not yet declared in ``cliAdapters``,
    /// in registry order.
    public var declarableCLIAdapters: [String] {
        let declared = Set(cliAdapters.map(\.name))
        return RegisteredCLIAdapters.names.filter { !declared.contains($0) }
    }

    /// A copy with `name` declared. `executable` is trimmed and becomes nil when empty. No other
    /// validation: the loader is the single validator, run when the result is saved.
    public func declaring(cliAdapter name: String, executable: String) -> MachineConfiguration {
        var copy = self
        let trimmed = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.cliAdapters.append(CLIAdapterDeclaration(name: name, executable: trimmed.isEmpty ? nil : trimmed))
        return copy
    }

    /// A copy with every declaration of `name` removed. No other validation: the loader is the single
    /// validator, run when the result is saved, so a route still naming `name` — in the base Routing Table
    /// or a Project's — refuses the save.
    public func removing(cliAdapter name: String) -> MachineConfiguration {
        var copy = self
        copy.cliAdapters.removeAll { $0.name == name }
        return copy
    }

    /// Whether some base Routing Table entry's route, or one of its fallbacks, names `cli`.
    public func baseRoutingTableNames(cliAdapter cli: String) -> Bool {
        routingTable.contains { entry in
            entry.route.cli == cli || entry.fallbacks.contains { $0.cli == cli }
        }
    }

    /// Whether some base Routing Table entry's route, or one of its fallbacks, names a declared CLI.
    public var hasRouteToDeclaredCLI: Bool {
        let declared = Set(cliAdapters.map(\.name))
        return routingTable.contains { entry in
            declared.contains(entry.route.cli) || entry.fallbacks.contains { declared.contains($0.cli) }
        }
    }
}
