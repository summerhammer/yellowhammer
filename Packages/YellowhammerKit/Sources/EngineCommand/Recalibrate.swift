import Config
import Domain
import Engine
import Foundation
import Journal

/// `yh recalibrate`'s orchestration, with the side effect (printing) injected as a seam, mirroring
/// ``Status``. Read-only: opens the Project's Journal with `JournalStore.openReadOnly`, never
/// `JournalStore.open` (which creates and migrates).
struct Recalibrate {
    let configurationDirectory: URL
    let output: (String) -> Void
    let json: Bool

    /// Runs the whole report for one already-resolved Project, returning the report so tests can
    /// inspect it directly. `project.id`/`project.bounds` are the Project this Project's `--project`
    /// (or its sole-Project default) resolved to.
    @discardableResult
    func run(project: ProjectConfiguration) throws -> RecalibrateReport {
        let journal: JournalStore?
        do {
            journal = try JournalStore.openReadOnly(
                at: JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: project.id),
                projectID: project.id
            )
        } catch JournalError.missing {
            journal = nil
        }

        let bounds = NightCardMaintenance.Bounds(
            reviewRoundsMax: project.bounds.reviewRoundsMax,
            attemptsPerWorkCard: project.bounds.attemptsPerWorkCard,
            unansweredNightsMax: project.bounds.unansweredNightsMax,
            reselectionsMax: project.bounds.reselectionsMax,
            consecutiveRefusalsMax: project.bounds.consecutiveRefusalsMax,
            failedAdoptionsMax: project.bounds.failedAdoptionsMax
        )

        let night = try journal.flatMap { try Self.thisNight(journal: $0) }
        let proximities = try night.flatMap { record in
            try journal.map { try NightSummary.boundProximity(night: record, journal: $0, bounds: bounds) }
        }

        let report = RecalibrateReport(
            project: project.id.rawValue,
            night: night.map(RecalibrateNight.init),
            bounds: Self.boundEntries(bounds: bounds, proximities: proximities)
        )

        if json {
            output(try Self.encode(report))
        } else {
            printText(report: report)
        }
        return report
    }

    /// "This Night" = the most recent open Night if any, else the most recent Night by `nightStart`.
    private static func thisNight(journal: JournalStore) throws -> NightRecord? {
        let nights = try journal.nights(mode: .real)
        if let openNight = nights.filter({ $0.completedAt == nil }).max(by: { $0.nightStart < $1.nightStart }) {
            return openNight
        }
        return nights.max(by: { $0.nightStart < $1.nightStart })
    }

    private static func boundEntries(
        bounds: NightCardMaintenance.Bounds, proximities: [BoundProximity]?
    ) -> [RecalibrateBound] {
        let proximityByName = Dictionary(uniqueKeysWithValues: (proximities ?? []).map { ($0.name, $0) })
        return Self.consequences.map { consequence in
            let proximity = proximityByName[consequence.name]
            return RecalibrateBound(
                name: consequence.name, consequenceShape: consequence.shape, consequence: consequence.wording,
                value: Self.value(name: consequence.name, bounds: bounds),
                proximity: proximity?.observed, measure: proximity?.measure
            )
        }
    }

    private static func value(name: String, bounds: NightCardMaintenance.Bounds) -> Int {
        switch name {
        case "review_rounds_max": return bounds.reviewRoundsMax
        case "attempts_per_work_card": return bounds.attemptsPerWorkCard
        case "overdue_nights_max": return bounds.unansweredNightsMax
        case "reselections_max": return bounds.reselectionsMax
        case "consecutive_refusals_max": return bounds.consecutiveRefusalsMax
        default: return bounds.failedAdoptionsMax
        }
    }

    /// One Bound's consequence shape and wording, fixed by which Bound it is (spec object-map → Bound).
    private struct Consequence {
        let name: String
        let shape: String
        let wording: String
    }

    /// Every Bound's consequence, in the same six-Bound order ``BoundProximity`` reports.
    private static let consequences: [Consequence] = [
        Consequence(name: "review_rounds_max", shape: "stops", wording: "stops work on a Card"),
        Consequence(name: "attempts_per_work_card", shape: "stops", wording: "stops work on a Card"),
        Consequence(
            name: "overdue_nights_max", shape: "stops", wording: "stops an unanswered Card's remaining work"
        ),
        Consequence(name: "reselections_max", shape: "stops", wording: "stops the Night's authoring"),
        Consequence(name: "consecutive_refusals_max", shape: "promotes", wording: "promotes to a standing item"),
        Consequence(name: "failed_adoptions_max", shape: "promotes", wording: "promotes to a standing item")
    ]

    private static func encode(_ report: RecalibrateReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private func printText(report: RecalibrateReport) {
        if let night = report.night {
            output("Project \(report.project): this Night is \(night.nightStart) (\(night.mode), \(night.state)).")
        } else {
            output("Project \(report.project): no Night recorded in this Project's Journal.")
        }
        for bound in report.bounds {
            if let proximity = bound.proximity {
                let measureSuffix = bound.measure.map { " (\($0))" } ?? ""
                output(
                    "`\(bound.name)` = \(bound.value) — \(bound.consequence); " +
                        "this Night: \(proximity) of \(bound.value)\(measureSuffix)."
                )
            } else {
                output("`\(bound.name)` = \(bound.value) — \(bound.consequence); this Night: no Night recorded.")
            }
        }
    }
}

/// One Bound's report line: its configured value, its fixed consequence, and this Night's proximity
/// (nil when there is no Night to measure).
struct RecalibrateBound: Codable, Equatable {
    let name: String
    let consequenceShape: String
    let consequence: String
    let value: Int
    let proximity: Int?
    let measure: String?

    // `JSONEncoder` omits a nil `Optional` field by default; the `--json` contract writes `null`
    // instead, so `proximity` and `measure` are encoded explicitly rather than left to synthesis.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(consequenceShape, forKey: .consequenceShape)
        try container.encode(consequence, forKey: .consequence)
        try container.encode(value, forKey: .value)
        try container.encode(proximity, forKey: .proximity)
        try container.encode(measure, forKey: .measure)
    }
}

/// This Night's identity, as `--json` reports it.
struct RecalibrateNight: Codable, Equatable {
    let nightStart: String
    let mode: String
    let state: String

    init(_ night: NightRecord) {
        nightStart = night.nightStart.rawValue
        mode = night.mode.rawValue
        state = night.state.rawValue
    }
}

/// The whole `yh recalibrate` report, for both `--json` and for tests to inspect directly.
struct RecalibrateReport: Codable, Equatable {
    let project: String
    let night: RecalibrateNight?
    let bounds: [RecalibrateBound]

    // As with `RecalibrateBound`: `night` is written explicitly so a nil Night encodes as `null`
    // rather than an omitted key.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(project, forKey: .project)
        try container.encode(night, forKey: .night)
        try container.encode(bounds, forKey: .bounds)
    }
}
