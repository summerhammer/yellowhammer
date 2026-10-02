import Domain
import Foundation

extension MachineConfiguration {
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

    /// Whether some base Routing Table entry's route, or one of its fallbacks, names a declared CLI.
    public var hasRouteToDeclaredCLI: Bool {
        let declared = Set(cliAdapters.map(\.name))
        return routingTable.contains { entry in
            declared.contains(entry.route.cli) || entry.fallbacks.contains { declared.contains($0.cli) }
        }
    }
}
