import Config
import Foundation

extension Setup {
    /// A job request on an already configured machine uses each Project's saved connections. It does
    /// not select one connection for all Projects or enter the Project declaration wizard.
    func savedConfigurationForScheduledJobs() throws -> Configuration? {
        guard case .interactive = options.mode, options.jobs != .none else { return nil }
        let declaring = options.hasProjectDeclarationOptions || !options.cliAdapters.isEmpty || options.route != nil
        let selecting = options.installation != nil || options.installationName != nil
            || options.codeHostingConnection != nil || options.operatorID != nil
        guard !declaring, !selecting else {
            try requireScheduledJobsTTY(reason: "setup options request configuration input")
            return nil
        }

        let configuration: Configuration?
        do {
            configuration = try Configuration.loadIfSetUp(directory: configurationDirectory)
        } catch {
            throw SetupError("\(machineFileURL.path(percentEncoded: false)) is invalid: \(error)")
        }
        guard let configuration else {
            try requireScheduledJobsTTY(reason: "no saved machine configuration was found")
            return nil
        }
        if let id = options.projectID {
            guard configuration.projects.contains(where: { $0.id == id })
                || configuration.invalidProjects.contains(where: { $0.id == id }) else {
                try requireScheduledJobsTTY(reason: "Project \(id.rawValue) has no saved configuration")
                return nil
            }
        }
        guard !configuration.projects.isEmpty || !configuration.invalidProjects.isEmpty else {
            try requireScheduledJobsTTY(reason: "no saved Project configuration was found")
            return nil
        }
        return configuration
    }

    private func requireScheduledJobsTTY(reason: String) throws {
        guard isTTY() else {
            throw SetupError(
                "\(reason); setup needs input but standard input is not a terminal. "
                    + "Run yh setup interactively to configure the missing values, "
                    + "or use yh setup --init with explicit configuration options, then rerun --install-jobs "
                    + "or --export-jobs <directory>."
            )
        }
    }
}
