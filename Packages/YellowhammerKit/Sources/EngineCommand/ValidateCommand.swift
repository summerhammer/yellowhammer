import ArgumentParser
import Config
import Foundation

/// `yh validate`: offline configuration validation only (no Keychain, no Linear, no launchd) —
/// `DoctorCheck.configuration` alone, in the same output format and exit-code rule as `yh doctor`.
public struct ValidateCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate configuration offline: no Keychain, no Linear, no launchd."
    )

    public init() {}

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(configurationDirectory: URL) async throws {
        let doctor = DoctorCommand.makeDoctor(
            configurationDirectory: configurationDirectory,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            options: DoctorRunOptions(fix: false, yes: false, probe: false, checks: [.configuration])
        )
        let findings = await doctor.run()
        if findings.contains(where: { $0.severity == .failure }) {
            throw ExitCode(1)
        }
    }
}
