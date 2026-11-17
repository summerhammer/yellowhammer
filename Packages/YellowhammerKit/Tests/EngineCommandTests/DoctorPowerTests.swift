@testable import EngineCommand
import Foundation
import Testing

@Suite("Doctor: power check")
struct DoctorPowerTests {
    private func custom(battery: String, ac: String) -> String {
        """
        Battery Power:
         displaysleep         2
         disksleep            10
         sleep                \(battery)
        AC Power:
         displaysleep         10
         sleep                \(ac)
        """
    }

    @Test("Battery 1 and AC 0 give one warning naming the battery and 1 min")
    func batteryOnly() throws {
        let timers = try #require(PmsetPowerSettings.parse(custom(battery: "1", ac: "0")))
        #expect(timers == [
            PowerSourceSleep(source: "on battery", minutes: 1), PowerSourceSleep(source: "on AC power", minutes: 0)
        ])
    }

    @Test("A parenthetical suffix after the value still parses")
    func suffix() throws {
        let timers = try #require(
            PmsetPowerSettings.parse(custom(battery: "1 (sleep prevented by powerd)", ac: "0"))
        )
        #expect(timers.first?.minutes == 1)
    }

    @Test("Only displaysleep and disksleep non-zero is not a sleep timer")
    func onlyDisplaySleep() throws {
        let text = "AC Power:\n displaysleep 10\n disksleep 10\n sleep 0\n"
        let timers = try #require(PmsetPowerSettings.parse(text))
        #expect(timers == [PowerSourceSleep(source: "on AC power", minutes: 0)])
    }

    @Test("Output with no sleep line is unreadable")
    func unreadable() {
        #expect(PmsetPowerSettings.parse("") == nil)
        #expect(PmsetPowerSettings.parse("AC Power:\n displaysleep 10\n") == nil)
    }

    private func run(_ timers: [PowerSourceSleep]?) async throws -> [DoctorFinding] {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let doctor = makeDoctor(
            directory: directory, checks: [.configuration, .power], powerSettings: FakePowerSettings(timers: timers)
        )
        return await doctor.run().filter { $0.check == .power }
    }

    @Test("One non-zero source warns once, naming source and timer")
    func warnsOnce() async throws {
        let findings = try await run([
            PowerSourceSleep(source: "on battery", minutes: 1), PowerSourceSleep(source: "on AC power", minutes: 0)
        ])
        #expect(findings.map(\.severity) == [.warning])
        #expect(findings.first?.message == "on battery this Mac sleeps after 1 min; a Night needs it awake")
        #expect(findings.first?.projectID == nil)
    }

    @Test("Two non-zero sources warn twice")
    func warnsTwice() async throws {
        let findings = try await run([
            PowerSourceSleep(source: "on battery", minutes: 1), PowerSourceSleep(source: "on AC power", minutes: 30)
        ])
        #expect(findings.map(\.severity) == [.warning, .warning])
    }

    @Test("Every source at 0 passes with the closed-lid caveat")
    func passes() async throws {
        let findings = try await run([PowerSourceSleep(source: "on AC power", minutes: 0)])
        #expect(findings.map(\.severity) == [.pass])
        #expect(findings.first?.message.contains("closed lid") == true)
    }

    @Test("Unreadable settings warn and never fail")
    func unreadableWarns() async throws {
        let findings = try await run(nil)
        #expect(findings.map(\.severity) == [.warning])
        #expect(findings.first?.message.contains("could not be read") == true)
    }

    @Test("power runs last and leaves the failure count alone")
    func runsLast() async throws {
        #expect(DoctorCheck.allCases.last == .power)
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let sleepy = FakePowerSettings(timers: [PowerSourceSleep(source: "on battery", minutes: 1)])
        let doctor = makeDoctor(directory: directory, powerSettings: sleepy)
        let findings = await doctor.run()
        #expect(findings.last?.check == .power)
        #expect(!findings.filter { $0.check == .power }.contains { $0.severity == .failure })
    }
}
