import ArgumentParser
import Config
import Domain
import Foundation
import LinearAdapter

/// `yh config description-budget --board-connection <name> <budget>`: changes one Board Connection's
/// `description_budget`, the key of its `[board.linear.connections.<name>]` table (spec
/// `install-the-linear-app`, *budget in Settings*). Validated as at load: at least 1, and at most the
/// ceiling of the board's description limit, which only the engine side knows. Lowering it changes no card
/// already written, until that card's next rewrite.
public struct ConfigDescriptionBudgetCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "description-budget",
        abstract: "Change a Board Connection's description budget."
    )

    @Option(name: .customLong("board-connection"), help: "The local name of the Board Connection.")
    public var boardConnection: String

    @Argument(help: "The description budget, at least 1 and at most 90% of the board's description limit.")
    public var budget: Int

    public init() {}

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(configurationDirectory: URL, output: @escaping (String) -> Void = { print($0) }) throws {
        let change = ConfigDescriptionBudgetChange(configurationDirectory: configurationDirectory, output: output)
        guard change.run(boardConnection: boardConnection, budget: budget) else { throw ExitCode(1) }
    }
}

/// `yh config description-budget`'s orchestration. Every refusal writes nothing; a success rewrites only the
/// one connection's `description_budget` line, and the edited text is re-parsed before it is written.
struct ConfigDescriptionBudgetChange {
    /// The largest budget the board accepts: 90% of Linear's description limit, which only the engine side knows.
    static let ceiling = LinearAdapter.descriptionLimit.budgetCeiling

    let configurationDirectory: URL
    let output: (String) -> Void

    var machineFileURL: URL {
        configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory)
    }

    /// Returns whether the change succeeded, the command's exit code.
    func run(boardConnection name: String, budget: Int) -> Bool {
        do {
            let machine = try MachineConfiguration.load(contentsOf: machineFileURL)
            guard var installation = machine.linearInstallation(named: name) else {
                let names = machine.linearInstallations.map(\.name)
                throw SetupError(
                    "no Board Connection is named \"\(name)\"; valid names: \(names.joined(separator: ", "))"
                )
            }
            installation.descriptionBudget = budget
            do {
                _ = try installation.descriptionBudget(limit: LinearAdapter.descriptionLimit)
            } catch {
                throw SetupError("description_budget \(error.reason)")
            }
            try write(budget, installation: name)
            output("Board Connection \(name): description budget is now \(budget)")
            output("Lowering it changes no card already written until that card's next rewrite.")
            return true
        } catch {
            output("\(error)")
            return false
        }
    }

    private func write(_ budget: Int, installation name: String) throws {
        let path = machineFileURL.path(percentEncoded: false)
        let text: String
        do {
            text = try String(contentsOf: machineFileURL, encoding: .utf8)
        } catch {
            throw SetupError("could not read \(path): \(error)")
        }
        let updated = MachineConfiguration.settingDescriptionBudget(budget, installation: name, inFileText: text)
        do {
            _ = try MachineConfiguration.parse(updated, file: path)
        } catch {
            throw SetupError("could not set the description budget: \(error)")
        }
        do {
            try updated.write(to: machineFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw SetupError("could not write \(path): \(error)")
        }
    }
}
