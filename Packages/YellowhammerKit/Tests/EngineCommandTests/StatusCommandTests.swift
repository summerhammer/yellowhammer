import Config
import Domain
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

@Suite("Status: exit conditions and cross-Project isolation")
struct StatusCommandTests {
    private static let now = statusTestDate("2026-09-24 10:00:00 +0000")

    @Test("A malformed machine file fails the report; nothing else runs")
    func malformedMachineFileFails() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("not valid toml [[[")
        try directory.writeValidProjectFile(id: "alpha")

        let output = RecordingOutput()
        let status = makeStatus(directory: directory, output: output, now: Self.now)
        let report = await status.run()

        #expect(report.machineFileFailed)
        #expect(report.projectStatuses.isEmpty)
        #expect(report.invalidProjectStatuses.isEmpty)
    }

    @Test("--project naming a Project configuration has neither valid nor invalid reports unknownProject")
    func unknownProjectFilter() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let status = makeStatus(
            directory: directory, now: Self.now, projectFilter: ProjectID(rawValue: "ghost")!
        )
        let report = await status.run()

        #expect(report.unknownProject)
        #expect(!report.machineFileFailed)
        #expect(report.projectStatuses.isEmpty)
    }

    @Test("--project reports only the named Project")
    func projectFilterReportsOnlyThatProject() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        try directory.writeValidProjectFile(id: "beta")

        let output = RecordingOutput()
        let status = makeStatus(
            directory: directory, output: output, now: Self.now, projectFilter: ProjectID(rawValue: "alpha")!
        )
        let report = await status.run()

        #expect(report.projectStatuses.map(\.projectID.rawValue) == ["alpha"])
        #expect(!output.lines.contains { $0.contains("Project beta") })
    }

    @Test("--project matches an invalid Project by its file name when its id could not be decoded")
    func projectFilterMatchesInvalidProjectByFile() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeProjectFile(id: "broken", "not valid toml [[[")

        let status = makeStatus(
            directory: directory, now: Self.now, projectFilter: ProjectID(rawValue: "broken")!
        )
        let report = await status.run()

        #expect(!report.unknownProject)
        #expect(report.invalidProjectStatuses.count == 1)
    }

    @Test("Two Projects' sections carry no shared verdict: one Project's missed Night never appears in the other's")
    func twoProjectsCarryNoSharedVerdict() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        try directory.writeValidProjectFile(id: "beta")

        // alpha: a recorded Night for the examined window, so nothing is missed.
        let alphaID = ProjectID(rawValue: "alpha")!
        let alphaJournal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: alphaID)
        try recordNight(
            in: alphaJournal, nightStart: NightStart(rawValue: "2026-09-23")!, act: .land,
            openedAt: statusTestDate("2026-09-23 22:05:00 +0000"), closeReason: .nightEnd,
            closedAt: statusTestDate("2026-09-24 06:00:00 +0000")
        )
        // beta: no Journal at all, so its one examined window is missed (no runnable job).
        let output = RecordingOutput()
        let status = makeStatus(directory: directory, output: output, now: Self.now)
        let report = await status.run()

        let alphaStatus = try #require(report.projectStatuses.first { $0.projectID.rawValue == "alpha" })
        let betaStatus = try #require(report.projectStatuses.first { $0.projectID.rawValue == "beta" })
        #expect(alphaStatus.missedNights.isEmpty)
        #expect(!betaStatus.missedNights.isEmpty)

        // No cross-Project verdict: nothing in the output aggregates both Projects into one line.
        #expect(!output.lines.contains { $0.contains("alpha") && $0.contains("beta") })
        #expect(output.lines.filter { $0.hasPrefix("Project ") }.count == 2)
    }
}
