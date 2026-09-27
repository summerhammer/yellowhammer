import ArgumentParser
@testable import EngineCommand
import Testing

@Suite("DoctorCommand/ValidateCommand parsing and exit code")
struct DoctorCommandTests {
    @Test("DoctorCommand accepts --fix, --yes and --probe")
    func doctorParsesFlags() throws {
        let command = try DoctorCommand.parse(["--fix", "--yes", "--probe"])
        #expect(command.fix)
        #expect(command.yes)
        #expect(command.probe)
    }

    @Test("ValidateCommand takes no --fix: validate never checks orphans")
    func validateRejectsFix() {
        #expect(throws: (any Error).self) { try ValidateCommand.parse(["--fix"]) }
    }

    @Test("DoctorCommand: --yes without --fix is a validation error")
    func doctorYesWithoutFixIsValidationError() {
        #expect(throws: (any Error).self) { try DoctorCommand.parse(["--yes"]) }
    }

    @Test("Doctor exits non-zero when a finding is a failure")
    func exitsNonZeroOnFailure() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("not valid toml [[[")
        let command = try DoctorCommand.parse([])
        await #expect(throws: ExitCode.self) {
            try await command.run(configurationDirectory: directory.url)
        }
    }

    @Test("Validate passes with a valid configuration directory and no other checks run")
    func validatePassesOnValidConfiguration() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let command = try ValidateCommand.parse([])
        try await command.run(configurationDirectory: directory.url)
    }

    @Test("DoctorCommand accepts --check and --json") // glossary:ignore GL001
    func doctorParsesCheckAndJSON() throws {
        let command = try DoctorCommand.parse(["--check", "linear", "--json"])
        #expect(command.check == "linear")
        #expect(command.json)
    }

    @Test("--check with an unknown name is a validation error")
    func doctorUnknownCheckIsValidationError() {
        #expect(throws: (any Error).self) { try DoctorCommand.parse(["--check", "bogus"]) }
    }

    @Test("--check narrows to one check: --check configuration passes despite no Linear installation")
    func checkNarrowsToOneCheck() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        // The default (every check) run fails: no Installation token pair is present.
        let everyCheck = try DoctorCommand.parse([])
        await #expect(throws: ExitCode.self) { try await everyCheck.run(configurationDirectory: directory.url) }

        // Narrowed to --check configuration, the same directory passes.
        let onlyConfiguration = try DoctorCommand.parse(["--check", "configuration", "--json"])
        try await onlyConfiguration.run(configurationDirectory: directory.url)
    }
}
