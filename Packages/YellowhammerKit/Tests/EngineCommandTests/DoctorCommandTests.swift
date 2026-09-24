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
}
