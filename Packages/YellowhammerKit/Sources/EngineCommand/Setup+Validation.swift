import Config

extension Setup {
    /// Step 5: loads and validates the whole directory. A machine error means throw; each invalid
    /// Project is printed here rather than thrown immediately, so a valid sibling still gets provisioned.
    func validateConfiguration() throws -> Configuration {
        let configuration: Configuration
        do {
            configuration = try Configuration.load(directory: configurationDirectory)
        } catch {
            throw SetupError("\(machineFileURL.path(percentEncoded: false)) is invalid: \(error)")
        }
        for invalid in configuration.invalidProjects {
            output("invalid \(invalid.file):")
            for error in invalid.errors {
                output("  \(error)")
            }
        }
        return configuration
    }
}
