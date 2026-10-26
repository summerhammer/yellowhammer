import Config
import Domain
import Foundation
import Pulse

@testable import Journal

// The self-check: re-opens both Journals read-only and checks every fact the screenshots rely on.

extension Showcase {
    /// Reads `<directory>/morning/` and `<directory>/working/` back as the app does, as of `now`, and throws
    /// a ``ShowcaseError`` naming the first fact that does not hold.
    public static func verify(directory: URL, now: Date) throws {
        let morning = try read(.morning, in: directory, asOf: now)
        try verifyMorning(morning.snapshot, account: morning.account)
        let working = try read(.working, in: directory, asOf: now)
        try verifyWorking(working.snapshot)
        for kind in ShowcaseKind.allCases {
            try verifyConfiguration(directory.appending(component: kind.rawValue, directoryHint: .isDirectory))
        }
    }

    private static func read(
        _ kind: ShowcaseKind, in directory: URL, asOf now: Date
    ) throws -> (snapshot: PulseSnapshot, account: NightAccount) {
        let target = directory.appending(component: kind.rawValue, directoryHint: .isDirectory)
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: target, id: try projectID())
        let journal = try JournalStore.openReadOnly(at: fileURL, projectID: projectID())
        let snapshot = try PulseSnapshot.read(from: journal, status: .idle, asOf: now)
        let nightID = try required(snapshot.night?.id, "\(kind.rawValue) Night")
        return (snapshot, try required(try NightAccount.read(from: journal, nightID: nightID), "Night account"))
    }

    private static func verifyMorning(_ snapshot: PulseSnapshot, account: NightAccount) throws {
        let night = try required(snapshot.night, "morning Night")
        try check(night.state == .done, "morning: Night is \(night.state), not done")
        try check(
            night.verdictLine == "Feature ORB-212 verified \u{2014} all 18 clauses met",
            "morning: verdict line is \(night.verdictLine ?? "nil")"
        )
        try check(night.nightCard?.identifier == "ORB-200", "morning: Night Card is not ORB-200")
        try check(night.cardsByDisposition.map(\.disposition) == [.done], "morning: not every Card is Done")
        try check(night.cardsByDisposition.first?.count == 7, "morning: not seven Done Cards")
        try check(snapshot.needsYou.cards.isEmpty, "morning: a Card needs you")
        try check(snapshot.now.attempts.isEmpty, "morning: an Attempt is open")
        try check(snapshot.now.status == .idle, "morning: the Project is working")
        try check(snapshot.health == nil, "morning: Health is not clean")

        let feature = try required(snapshot.feature, "morning Feature")
        try check(feature.id == issueID(212), "morning: Feature is not ORB-212's issue")
        try check(feature.link?.identifier == "ORB-212", "morning: Feature link is not ORB-212")
        try check(feature.verification?.met == 18, "morning: Verification does not show 18 met")
        try check(feature.lanes.count == 3, "morning: \(feature.lanes.count) lanes, not 3")
        let numbers = Dictionary(uniqueKeysWithValues: feature.lanes.map { ($0.repo, $0.pullRequest?.number) })
        try check(
            numbers == [apiRepo: 418, webRepo: 233, iosRepo: 97], "morning: pull requests are \(numbers)"
        )

        let problems = account.runs.flatMap(\.entries).filter(\.isProblem)
        try check(account.problemCount == 1, "morning: \(account.problemCount) problems, not 1")
        try check(problems.first?.headline == "ORB-214: Attempt ended", "morning: the problem is not ORB-214's")
        try check(
            problems.first?.detail == "hard failure on codex/gpt-5.4/high; Route excluded",
            "morning: the problem reads \(problems.first?.detail ?? "nil")"
        )
        try check(account.runs.allSatisfy { $0.outcome != .notEnded }, "morning: an Act run recorded no end")
    }

    private struct OpenAttempt {
        let card: String
        let id: String
        let route: String
        let repo: String
        let round: Int
    }

    private static func verifyWorking(_ snapshot: PulseSnapshot) throws {
        try check(snapshot.now.status == .working, "working: the Project is not working")
        try check(snapshot.night?.state == .running, "working: the Night is not running")
        try check(snapshot.night?.nightCard?.identifier == "ORB-200", "working: Night Card is not ORB-200")
        try check(snapshot.needsYou.cards.isEmpty, "working: a Card needs you")
        try check(snapshot.health == nil, "working: Health is not clean")

        let attempts = snapshot.now.attempts
        try check(attempts.count == 3, "working: \(attempts.count) open Attempts, not 3")
        let byCard = Dictionary(uniqueKeysWithValues: attempts.map { ($0.cardIDForDisplay, $0) })
        let expected = [
            OpenAttempt(card: "ORB-214", id: retriedAttemptID, route: "claude/opus/high", repo: apiRepo, round: 1),
            OpenAttempt(card: "ORB-216", id: "4", route: "codex/gpt-5.4/high", repo: webRepo, round: 2),
            OpenAttempt(card: "ORB-218", id: "6", route: "agy/gemini-3-pro/high", repo: iosRepo, round: 1)
        ]
        for fact in expected {
            let attempt = try required(byCard[fact.card], "working Attempt of \(fact.card)")
            try check(
                attempt.id == fact.id && attempt.route == fact.route && attempt.repo == fact.repo
                    && attempt.round == fact.round,
                "working: \(fact.card) is attempt \(attempt.id) on \(attempt.route), Round \(attempt.round)"
            )
        }
        let cards = snapshot.feature?.lanes.flatMap(\.cards) ?? []
        let states = Dictionary(uniqueKeysWithValues: cards.map { ($0.issueIDForDisplay, $0.state) })
        let wanted: [String: CardState] = ["ORB-213": .done, "ORB-215": .done, "ORB-217": .todo, "ORB-219": .todo]
        try check(wanted.allSatisfy { states[$0.key] == $0.value }, "working: Card states are \(states)")
        try check(
            snapshot.feature?.lanes.allSatisfy { $0.pullRequest == nil } == true, "working: a pull request exists"
        )
    }

    private static func verifyConfiguration(_ directory: URL) throws {
        let loaded: Configuration?
        do {
            loaded = try Configuration.loadIfSetUp(directory: directory)
        } catch {
            throw ShowcaseError(description: "\(directory.lastPathComponent): configuration does not load: \(error)")
        }
        let configuration = try required(loaded, "\(directory.lastPathComponent) config.toml")
        try check(configuration.invalidProjects.isEmpty, "\(directory.lastPathComponent): an invalid Project")
        try check(
            configuration.projects.map(\.id.rawValue) == ["harbor", "orbit"],
            "\(directory.lastPathComponent): Projects are \(configuration.projects.map(\.id.rawValue))"
        )
        let journals = directory.appending(component: "journals", directoryHint: .isDirectory)
        try check(
            FileManager.default.fileExists(atPath: journals.appending(component: "orbit.db").path),
            "\(directory.lastPathComponent): orbit has no Journal"
        )
        try check(
            !FileManager.default.fileExists(atPath: journals.appending(component: "harbor.db").path),
            "\(directory.lastPathComponent): harbor has a Journal"
        )
    }

    /// Seeds the morning Night in `Europe/Kyiv` on the night its clocks go back (2026-10-25) and checks that
    /// it still opens at local 22:00 and closes at local 06:00 the next day.
    public static func selfTestDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try required(TimeZone(identifier: "Europe/Kyiv"), "Europe/Kyiv time zone")
        let now = try required(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 20)))
        let clock = ShowcaseClock(now: now, calendar: calendar)
        func local(_ date: Date) -> DateComponents {
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        }
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> DateComponents {
            DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)
        }
        try check(try clock.nightStart().rawValue == "2026-10-25", "Night start is not 2026-10-25")
        try check(local(clock.night(22, 0)) == at(25, 22, 0), "22:00 reads \(local(clock.night(22, 0)))")
        try check(local(clock.night(22, 16)) == at(25, 22, 16), "22:16 reads \(local(clock.night(22, 16)))")
        try check(local(clock.night(29, 30)) == at(26, 5, 30), "05:30 reads \(local(clock.night(29, 30)))")

        let scratch = FileManager.default.temporaryDirectory
            .appending(component: "yh-showcase-dst-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try write(to: scratch, now: now, calendar: calendar)
        let fileURL = JournalStore.defaultFileURL(
            configurationDirectory: scratch.appending(component: "morning", directoryHint: .isDirectory),
            id: try projectID()
        )
        let journal = try JournalStore.openReadOnly(at: fileURL, projectID: projectID())
        let night = try required(try journal.nights(mode: .real).first)
        try check(night.nightStart.rawValue == "2026-10-25", "seeded Night is \(night.nightStart.rawValue)")
        try check(local(night.openedAt) == at(25, 22, 0), "Night opened at \(local(night.openedAt))")
        let closed = try required(night.completedAt, "Night completion")
        try check(local(closed) == at(26, 6, 0), "Night closed at \(local(closed))")
    }
}
