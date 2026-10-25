import ArgumentParser
import Config
import Domain
import Foundation

/// `yh prompts`: manage recorded dispatch prompts.
public struct PromptsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "prompts",
        abstract: "Manage recorded dispatch prompts.",
        subcommands: [
            Delete.self
        ]
    )

    public init() {}
}

extension PromptsCommand {
    /// `yh prompts delete`: delete selected prompt records in project or machine scope.
    public struct Delete: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete prompt records in a project or machine scope."
        )

        @Option(help: "The id of the Project whose prompt records to delete.")
        public var project: String?

        @Flag(help: "Delete machine-scoped diagnostic prompt records.")
        public var machine: Bool = false

        @Argument(help: "The prompt record ids to delete.")
        public var ids: [String] = []

        public init() {}

        public func run() async throws {
            let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            try await run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
        }

        func run(
            configurationDirectory: URL,
            output: (String) -> Void = { print($0) },
            sweepLog: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        ) async throws {
            if ids.isEmpty {
                throw ValidationError("at least one prompt record id is required")
            }
            if project != nil && machine {
                throw ValidationError("cannot specify both --project and --machine")
            }
            guard let scope = try resolveScope(configurationDirectory: configurationDirectory) else {
                throw ValidationError("must specify either --project <id> or --machine")
            }

            let store = DispatchPromptStore(
                rootDirectory: DispatchPromptStore.rootDirectory(configurationDirectory: configurationDirectory)
            )

            let sweepFailures = store.sweepExpired(in: scope)
            for failure in sweepFailures {
                sweepLog("failed to sweep expired prompt record \(failure)")
            }

            let deletions = store.delete(ids: ids, in: scope)
            var hasFailure = false
            for (id, deletion) in zip(ids, deletions) {
                switch deletion {
                case .deleted:
                    output("deleted \(id)")
                case .alreadyMissing:
                    output("already deleted \(id)")
                case .failed(let cause):
                    output("failed \(id): \(cause)")
                    hasFailure = true
                }
            }

            if hasFailure {
                throw ExitCode(1)
            }
        }

        private func resolveScope(configurationDirectory: URL) throws -> DispatchPromptScope? {
            if machine {
                return .machine
            }
            if let project {
                let (_, resolved) = try ProjectResolution.resolve(
                    projectArgument: project, configurationDirectory: configurationDirectory
                )
                return .project(resolved.id)
            }
            return nil
        }
    }
}

public typealias PromptsDeleteCommand = PromptsCommand.Delete
