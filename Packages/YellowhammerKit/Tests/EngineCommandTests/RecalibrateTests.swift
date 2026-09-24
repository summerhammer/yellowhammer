import Config
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

@Suite("Recalibrate: one Project's Bounds and this Night's proximity")
struct RecalibrateTests {
    @Test("No Journal: every Bound reports its value with no proximity")
    func noJournalReportsBoundsWithoutProximity() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let (_, project) = try ProjectResolution.resolve(
            projectArgument: "alpha", configurationDirectory: directory.url
        )
        let output = RecordingOutput()
        let recalibrate = Recalibrate(configurationDirectory: directory.url, output: { output.record($0) }, json: false)
        let report = try recalibrate.run(project: project)

        #expect(report.project == "alpha")
        #expect(report.night == nil)
        #expect(report.bounds.count == 6)
        #expect(report.bounds.allSatisfy { $0.proximity == nil && $0.measure == nil })
        #expect(report.bounds.first { $0.name == "review_rounds_max" }?.value == 2)
        #expect(output.lines.contains { $0.contains("no Night recorded in this Project's Journal") })
        #expect(output.lines.contains { $0.contains("no Night recorded") && $0.contains("review_rounds_max") })
    }

    @Test("A Night's proximity matches what the Night Summary's own lines report for that Night")
    func proximityMatchesNightSummary() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let projectID = try #require(ProjectID(rawValue: "alpha"))
        let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)
        let run = RunID()
        _ = try journal.claimActLease(act: .land, runID: run, mode: .real)
        let start = try #require(NightStart(rawValue: "2026-09-25"))
        let night = try journal.openNight(nightStart: start, mode: .real, act: .land, runID: run).night
        try journal.append(
            .featureReselected(depth: 1, afterRefusalOf: "FEAT-OLD", reselectionsMax: 2), nightID: night.id
        )
        try journal.append(.refusalOpened(feature: "FEAT-OLD", consecutiveRefusals: 2), nightID: night.id)
        _ = try journal.claimActLease(act: .land, runID: run, mode: .real)
        _ = try journal.closeNight(id: night.id, reason: .nightEnd, act: .land, runID: run)
        let closed = try #require(try journal.night(id: night.id))

        let bounds = NightCardMaintenance.Bounds()
        let summaryLines = try NightSummary.instrumentedRateLines(night: closed, journal: journal, bounds: bounds)

        let (_, project) = try ProjectResolution.resolve(
            projectArgument: "alpha", configurationDirectory: directory.url
        )
        let output = RecordingOutput()
        let recalibrate = Recalibrate(configurationDirectory: directory.url, output: { output.record($0) }, json: false)
        let report = try recalibrate.run(project: project)

        #expect(report.night?.nightStart == "2026-09-25")
        #expect(report.night?.mode == "real")
        #expect(report.night?.state == "closed")

        let reselections = try #require(report.bounds.first { $0.name == "reselections_max" })
        let refusals = try #require(report.bounds.first { $0.name == "consecutive_refusals_max" })
        #expect(reselections.proximity == 1)
        #expect(refusals.proximity == 2)
        #expect(summaryLines.contains("`reselections_max`: \(reselections.proximity!) of \(reselections.value)."))
        #expect(summaryLines.contains("`consecutive_refusals_max`: \(refusals.proximity!) of \(refusals.value)."))

        let roundsBound = try #require(report.bounds.first { $0.name == "review_rounds_max" })
        #expect(roundsBound.measure == "highest Rounds in an Attempt")
        #expect(output.lines.contains {
            $0.contains("`reselections_max` = 2") && $0.contains("this Night: 1 of 2")
        })
    }

    @Test("--json encodes the exact contract shape")
    func jsonShape() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let (_, project) = try ProjectResolution.resolve(
            projectArgument: "alpha", configurationDirectory: directory.url
        )
        let output = RecordingOutput()
        let recalibrate = Recalibrate(configurationDirectory: directory.url, output: { output.record($0) }, json: true)
        try recalibrate.run(project: project)

        #expect(output.lines.count == 1)
        let line = try #require(output.lines.first)
        let data = try #require(line.data(using: .utf8))
        let decoded = try JSONDecoder().decode(RecalibrateReport.self, from: data)
        #expect(decoded.project == "alpha")
        #expect(decoded.night == nil)
        #expect(decoded.bounds.count == 6)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["project"] as? String == "alpha")
        #expect(json["night"] is NSNull)
        let bounds = try #require(json["bounds"] as? [[String: Any]])
        let reviewRounds = try #require(bounds.first { $0["name"] as? String == "review_rounds_max" })
        #expect(reviewRounds["consequenceShape"] as? String == "stops")
        #expect(reviewRounds["consequence"] as? String == "stops work on a Card")
        #expect(reviewRounds["value"] as? Int == 2)
        #expect(reviewRounds["proximity"] is NSNull)
        #expect(reviewRounds["measure"] is NSNull)
        let refusals = try #require(bounds.first { $0["name"] as? String == "consecutive_refusals_max" })
        #expect(refusals["consequenceShape"] as? String == "promotes")
        #expect(refusals["consequence"] as? String == "promotes to a standing item")
    }

    @Test("More than one configured Project without --project is refused, listing the configured ids")
    func moreThanOneProjectRequiresExplicitProject() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        try directory.writeValidProjectFile(id: "beta")

        do {
            _ = try ProjectResolution.resolveDefaultingToSoleProject(
                projectArgument: nil, configurationDirectory: directory.url
            )
            Issue.record("Expected a refusal")
        } catch {
            #expect(error == .projectRequired(ids: ["alpha", "beta"]))
            #expect("\(error)".contains("alpha"))
            #expect("\(error)".contains("beta"))
        }
    }

    @Test("Exactly one configured Project defaults to it when --project is omitted")
    func oneProjectDefaultsWithoutExplicitProject() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let (_, project) = try ProjectResolution.resolveDefaultingToSoleProject(
            projectArgument: nil, configurationDirectory: directory.url
        )
        #expect(project.id.rawValue == "alpha")
    }
}
