import CLIAdapters
import Config
import Domain
import Foundation

extension Setup {
    /// Step 1: loads `config.toml` if it exists — invalid means throw, and the file is never
    /// overwritten — or builds and writes it, from the options in `--init`, by prompting for whatever
    /// they did not supply when interactive.
    func loadOrCreateMachineFile() throws -> MachineConfiguration {
        let path = machineFileURL.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: path) {
            do {
                let machine = try MachineConfiguration.load(contentsOf: machineFileURL)
                output("kept \(path)")
                return machine
            } catch where error.reason == .legacyLinearClientID {
                return try removeLegacyLinearClientIDAndReload(path: path)
            } catch {
                throw SetupError("\(path) is invalid: \(error)")
            }
        }
        let machine = try isInteractive
            ? buildMachineConfigurationInteractively()
            : buildMachineConfigurationFromOptions(path: path)
        do {
            try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
            try machine.renderedTOML.write(to: machineFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw SetupError("could not write \(path): \(error)")
        }
        output("wrote \(path)")
        return machine
    }

    /// `[linear].client_id` is the withdrawn client-credentials setup's leftover (P17.4/P17.6): setup is
    /// the fix, so a machine file naming only that stale key is repaired in place, once, rather than
    /// refusing forever. Any other decode failure after the strip still throws normally.
    private func removeLegacyLinearClientIDAndReload(path: String) throws -> MachineConfiguration {
        let text: String
        do {
            text = try String(contentsOf: machineFileURL, encoding: .utf8)
        } catch {
            throw SetupError("\(path) is invalid: \(error)")
        }
        let repaired = MachineConfiguration.removingLegacyLinearClientID(inFileText: text)
        do {
            try repaired.write(to: machineFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw SetupError("could not write \(path): \(error)")
        }
        output("removed the withdrawn [linear].client_id from \(path)")
        do {
            let machine = try MachineConfiguration.load(contentsOf: machineFileURL)
            output("kept \(path)")
            return machine
        } catch {
            throw SetupError("\(path) is invalid: \(error)")
        }
    }

    private func buildMachineConfigurationFromOptions(path: String) throws -> MachineConfiguration {
        MachineConfiguration(
            linearCredential: options.linearCredential ?? Self.defaultLinearCredential,
            gitHubCredential: options.githubCredential ?? Self.defaultGitHubCredential,
            cliAdapters: options.cliAdapters,
            routingTable: options.route.map { [$0] } ?? []
        )
    }

    private func buildMachineConfigurationInteractively() throws -> MachineConfiguration {
        let linearCredential = try options.linearCredential ?? askCredential(
            "Linear credential reference [\(SetupOptions.defaultLinearCredential)]: ",
            default: SetupOptions.defaultLinearCredential
        )
        let githubCredential = try options.githubCredential ?? askCredential(
            "GitHub credential reference [\(SetupOptions.defaultGitHubCredential)]: ",
            default: SetupOptions.defaultGitHubCredential
        )
        let cliAdapters = try options.cliAdapters.isEmpty ? askCLIAdapters() : options.cliAdapters
        let route = try options.route ?? askRoute(declaredNames: Set(cliAdapters.map(\.name)))
        return MachineConfiguration(
            linearCredential: linearCredential, gitHubCredential: githubCredential,
            cliAdapters: cliAdapters, routingTable: route.map { [$0] } ?? []
        )
    }

    private static var defaultLinearCredential: CredentialReference {
        // Non-empty literal: never fails.
        CredentialReference(SetupOptions.defaultLinearCredential)!
    }

    private static var defaultGitHubCredential: CredentialReference {
        // Non-empty literal: never fails.
        CredentialReference(SetupOptions.defaultGitHubCredential)!
    }

    func askRequired(_ prompt: String) throws -> String {
        while true {
            guard let line = console.ask(prompt) else {
                throw SetupError("setup was cancelled")
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
    }

    /// `nil` from `console.ask` (EOF) always cancels; an empty answer takes `defaultValue`.
    private func askCredential(_ prompt: String, default defaultValue: String) throws -> CredentialReference {
        guard let line = console.ask(prompt) else {
            throw SetupError("setup was cancelled")
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let value = trimmed.isEmpty ? defaultValue : trimmed
        guard let reference = CredentialReference(value) else {
            throw SetupError("a credential reference must not be empty")
        }
        return reference
    }

    private func askCLIAdapters() throws -> [CLIAdapterDeclaration] {
        let known = CLIAdapterRegistry.allNames.joined(separator: ", ")
        while true {
            guard let line = console.ask("CLI Adapters, comma-separated (\(known)) []: ") else {
                throw SetupError("setup was cancelled")
            }
            let entries = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !entries.isEmpty else { return [] }
            do {
                return try SetupOptions.parseCLIAdapters(entries).0
            } catch {
                output("\(error)")
            }
        }
    }

    private func askRoute(declaredNames: Set<String>) throws -> RoutingEntry? {
        while true {
            guard let routeLine = console.ask("Catch-all route cli/model/effort (optional) []: ") else {
                throw SetupError("setup was cancelled")
            }
            let trimmedRoute = routeLine.trimmingCharacters(in: .whitespaces)
            guard !trimmedRoute.isEmpty else { return nil }
            guard let fallbackLine = console.ask("Fallbacks, comma-separated cli/model/effort (optional) []: ") else {
                throw SetupError("setup was cancelled")
            }
            let fallbacks = fallbackLine.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            do {
                return try SetupOptions.makeRoutingEntry(
                    route: trimmedRoute, fallbacks: fallbacks, declaredNames: declaredNames
                )
            } catch {
                output("\(error)")
            }
        }
    }
}
