import Config
import Domain
import Foundation
import Testing

private func projectID(_ string: String) throws -> ProjectID {
    try #require(ProjectID(rawValue: string))
}

private func projectText(schedule: String = "") -> String {
    """
    id = "alpha"
    name = "Alpha"
    board = { linear = { connection = "acme", project = "ALP" } }
    code_hosting = { connection = "github" }
    spec_source = "~/dev/alpha-spec"

    [[repos]]
    name = "backend"
    path = "~/dev/alpha"
    role = "backend"
    check = "swift test"
    \(schedule)
    """
}

private func parse(_ scheduleBody: String) throws -> ProjectConfiguration {
    try ProjectConfiguration.parse(projectText(schedule: "\n[schedule]\n\(scheduleBody)"), file: "alpha.toml")
}

private func refusal(_ scheduleBody: String) -> ConfigurationError? {
    do {
        _ = try parse(scheduleBody)
        return nil
    } catch {
        return error as? ConfigurationError
    }
}

private func project(_ id: String, stagger: Int?, window: (String, String) = ("22:00", "06:00")) throws
    -> ProjectConfiguration {
    ProjectConfiguration(
        id: try projectID(id), name: id, linearInstallationName: "acme", linearProject: id,
        codeHostingConnectionName: "github", specSource: "~/dev/\(id)-spec",
        repos: [RepoDeclaration(name: "r", path: "~/dev/\(id)", role: .backend, check: .command("true"))],
        schedule: Schedule(
            nightStart: try #require(TimeOfDay(window.0)), nightEnd: try #require(TimeOfDay(window.1)),
            staggerMinutes: stagger
        )
    )
}

private func assigned(_ projects: [ProjectConfiguration]) -> [String: Int] {
    var result: [String: Int] = [:]
    for (id, outcome) in StaggerAssignment.assignments(for: projects) {
        if case .assigned(let offset) = outcome { result[id.rawValue] = offset }
    }
    return result
}

@Suite("[schedule] stagger_minutes")
struct StaggerMinutesTests {
    // MARK: - Decoding

    @Test("An absent stagger_minutes reads as nil and an offset of 0; a recorded 0 stays recorded")
    func absentVersusZero() throws {
        let absent = try ProjectConfiguration.parse(projectText(), file: "alpha.toml")
        #expect(absent.schedule.staggerMinutes == nil)
        #expect(absent.schedule.staggerOffsetMinutes == 0)
        let noKey = try parse("night_start = \"22:00\"")
        #expect(noKey.schedule.staggerMinutes == nil)
        let zero = try parse("stagger_minutes = 0")
        #expect(zero.schedule.staggerMinutes == 0)
        #expect(try parse("stagger_minutes = 9").schedule.staggerOffsetMinutes == 9)
    }

    @Test("A negative stagger_minutes is refused at load")
    func negativeIsRefused() throws {
        let error = try #require(refusal("stagger_minutes = -3"))
        #expect(error.reason == .negativeStagger(-3))
        #expect(error.key == "schedule.stagger_minutes")
    }

    @Test("A non-integer stagger_minutes is refused at load")
    func nonIntegerIsRefused() throws {
        for body in ["stagger_minutes = 1.5", "stagger_minutes = \"3\""] {
            let error = try #require(refusal(body))
            guard case .typeMismatch(let expected, _) = error.reason else {
                Issue.record("expected typeMismatch for \(body), got \(error.reason)")
                continue
            }
            #expect(expected == "integer")
        }
    }

    @Test("A stagger_minutes at or past the window's length is refused; one below it is accepted")
    func beyondWindowIsRefused() throws {
        let window = "night_start = \"01:00\"\nnight_end = \"01:05\"\n"
        let error = try #require(refusal(window + "stagger_minutes = 5"))
        #expect(error.reason == .staggerBeyondWindow(offset: 5, windowMinutes: 5))
        #expect(try parse(window + "stagger_minutes = 4").schedule.staggerMinutes == 4)
        #expect(refusal("stagger_minutes = 480")?.reason == .staggerBeyondWindow(offset: 480, windowMinutes: 480))
        #expect(refusal("stagger_minutes = 479") == nil)
    }

    // MARK: - Assignment arithmetic

    @Test("Fresh alpha, beta, gamma get 0, 3, 6; adding aardvark assigns 9 and moves no sibling")
    func freshAssignmentAndAddingAProject() throws {
        let fresh = try ["gamma", "alpha", "beta"].map { try project($0, stagger: nil) }
        #expect(assigned(fresh) == ["alpha": 0, "beta": 3, "gamma": 6])

        let recorded = try [("alpha", 0), ("beta", 3), ("gamma", 6)].map { try project($0.0, stagger: $0.1) }
        let withAardvark = recorded + [try project("aardvark", stagger: nil)]
        #expect(assigned(withAardvark) == ["aardvark": 9])
    }

    @Test("Removing beta frees 3 for the next assigned Project, and siblings keep theirs")
    func removingAProjectFreesItsOffset() throws {
        let remaining = try [("alpha", 0), ("gamma", 6)].map { try project($0.0, stagger: $0.1) }
        let next = remaining + [try project("delta", stagger: nil)]
        #expect(assigned(next) == ["delta": 3])
    }

    @Test("Assignment is in sorted id order and earlier assignments in the run are held")
    func sortedOrderWithinOneRun() throws {
        let projects = try [("beta", 0), ("zeta", nil), ("alpha", nil), ("mu", nil)].map {
            try project($0.0, stagger: $0.1)
        }
        #expect(assigned(projects) == ["alpha": 3, "mu": 6, "zeta": 9])
        #expect(StaggerAssignment.assignments(for: projects).map(\.0.rawValue) == ["alpha", "mu", "zeta"])
    }

    @Test("Operator-set coinciding offsets are not refused, and an off-grid value only holds its own number")
    func operatorSetValues() throws {
        let projects = try [("alpha", 3), ("beta", 3), ("gamma", 4), ("delta", nil)].map {
            try project($0.0, stagger: $0.1)
        }
        #expect(assigned(projects) == ["delta": 0])
        let noZero = try [("alpha", 0), ("beta", 3), ("delta", nil)].map { try project($0.0, stagger: $0.1) }
        #expect(assigned(noZero) == ["delta": 6])
    }

    @Test("A lowest free offset past the window assigns nothing for that Project; siblings are still assigned")
    func overWindowAssignmentIsRefused() throws {
        // Window 01:00-01:05 is 5 minutes: offsets 0 and 3 fit, 6 does not.
        let short = ("01:00", "01:05")
        let projects = [
            try project("a", stagger: nil, window: short), try project("b", stagger: nil, window: short),
            try project("c", stagger: nil, window: short), try project("d", stagger: nil)
        ]
        let outcomes = Dictionary(uniqueKeysWithValues: StaggerAssignment.assignments(for: projects).map {
            ($0.0.rawValue, $0.1)
        })
        #expect(outcomes["a"] == .assigned(0))
        #expect(outcomes["b"] == .assigned(3))
        #expect(outcomes["c"] == .beyondWindow(offset: 6, windowMinutes: 5))
        // d is in the default 480-minute window, and 6 is still free for it: c's refusal held nothing.
        #expect(outcomes["d"] == .assigned(6))
    }

    @Test("eligible narrows who is assigned but not whose recorded value is held")
    func eligibleNarrowsAssignment() throws {
        let projects = try [("alpha", 0), ("beta", nil), ("gamma", nil)].map { try project($0.0, stagger: $0.1) }
        let outcomes = StaggerAssignment.assignments(for: projects, eligible: [try projectID("gamma")])
        #expect(outcomes.map(\.0.rawValue) == ["gamma"])
        #expect(outcomes.first?.1 == .assigned(3))
    }

    // MARK: - Text edit

    @Test("settingStaggerMinutes inserts into an existing [schedule], keeping every other line and comment")
    func textEditPreservesLines() throws {
        let text = projectText(schedule: """

            # when the Night runs
            [schedule]
            night_start = "21:00" # early
            build_every_minutes = 20

            [limits]
            review_rounds_max = 4
            """)
        let edited = ProjectConfiguration.settingStaggerMinutes(6, inFileText: text)

        #expect(edited == text.replacingOccurrences(
            of: "build_every_minutes = 20\n", with: "build_every_minutes = 20\nstagger_minutes = 6\n"
        ))
        #expect(edited.contains("# when the Night runs"))
        #expect(edited.contains("night_start = \"21:00\" # early"))
        let parsed = try ProjectConfiguration.parse(edited, file: "alpha.toml")
        #expect(parsed.schedule.staggerMinutes == 6)
        #expect(parsed.schedule.buildEveryMinutes == 20)
        #expect(ProjectConfiguration.settingStaggerMinutes(6, inFileText: edited) == edited)
    }

    @Test("settingStaggerMinutes appends a [schedule] table when the file has none, and is idempotent")
    func textEditAppendsATable() throws {
        let text = projectText() + "\n# trailing comment\n"
        let edited = ProjectConfiguration.settingStaggerMinutes(3, inFileText: text)

        #expect(edited.hasPrefix(text))
        #expect(edited.hasSuffix("\n[schedule]\nstagger_minutes = 3\n"))
        #expect(try ProjectConfiguration.parse(edited, file: "alpha.toml").schedule.staggerMinutes == 3)
        #expect(ProjectConfiguration.settingStaggerMinutes(3, inFileText: edited) == edited)
    }

    @Test("settingStaggerMinutes replaces a recorded value in place")
    func textEditReplaces() throws {
        let text = projectText(schedule: "\n[schedule]\nstagger_minutes = 0\n")
        let edited = ProjectConfiguration.settingStaggerMinutes(9, inFileText: text)
        #expect(try ProjectConfiguration.parse(edited, file: "alpha.toml").schedule.staggerMinutes == 9)
        #expect(edited.components(separatedBy: "stagger_minutes").count == 2)
    }

    // MARK: - Rendering round-trip

    @Test("A recorded stagger_minutes survives an app save; an absent one stays absent")
    func renderingRoundTrip() throws {
        let present = try project("alpha", stagger: 6)
        #expect(present.renderedTOML.contains("stagger_minutes = 6"))
        #expect(try ProjectConfiguration.parse(present.renderedTOML, file: "alpha.toml") == present)

        let zero = try project("alpha", stagger: 0)
        #expect(try ProjectConfiguration.parse(zero.renderedTOML, file: "alpha.toml").schedule.staggerMinutes == 0)

        let absent = try project("beta", stagger: nil)
        #expect(!absent.renderedTOML.contains("stagger_minutes"))
        #expect(try ProjectConfiguration.parse(absent.renderedTOML, file: "beta.toml").schedule.staggerMinutes == nil)
    }

    // MARK: - closesNight

    @Test("A land in [night_end, night_end + o) does not close the Night; one at night_end + o does")
    func closesNightBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        func instant(_ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            let components = DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute)
            return try #require(calendar.date(from: components))
        }
        let schedule = Schedule(staggerMinutes: 6)
        let window = schedule.nightWindow(at: try instant(15, 23, 0), calendar: calendar)

        #expect(!schedule.closesNight(at: try instant(16, 5, 59), in: window, calendar: calendar))
        #expect(!schedule.closesNight(at: try instant(16, 6, 0), in: window, calendar: calendar))
        #expect(!schedule.closesNight(at: try instant(16, 6, 5), in: window, calendar: calendar))
        #expect(schedule.closesNight(at: try instant(16, 6, 6), in: window, calendar: calendar))
        #expect(Schedule().closesNight(at: try instant(16, 6, 0), in: window, calendar: calendar))
    }
}
