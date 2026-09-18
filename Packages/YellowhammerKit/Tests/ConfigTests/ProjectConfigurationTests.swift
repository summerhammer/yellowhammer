import Config
import Domain
import Foundation
import Testing

private func fixture(_ name: String, in directory: String) throws -> URL {
    try #require(
        Bundle.module.url(forResource: name, withExtension: "toml", subdirectory: "Fixtures/Projects/\(directory)")
    )
}

private func route(_ cli: String, _ model: String, _ effort: String = "medium") throws -> Route {
    try #require(Route(cli: cli, model: model, effort: effort))
}

private func kind(_ string: String) throws -> Kind {
    try #require(Kind(string))
}

private func time(hour: Int, minute: Int) throws -> TimeOfDay {
    try #require(TimeOfDay(hour: hour, minute: minute))
}

private func projectID(_ string: String) throws -> ProjectID {
    try #require(ProjectID(rawValue: string))
}

@Test("A Project's default file is ~/.config/yellowhammer/projects/<id>.toml")
func projectDefaultFileURL() throws {
    let home = URL(filePath: "/Users/operator", directoryHint: .isDirectory)
    let id = try projectID("my-project")
    let url = ProjectConfiguration.defaultFileURL(homeDirectory: home, id: id)
    #expect(url.path(percentEncoded: false) == "/Users/operator/.config/yellowhammer/projects/my-project.toml")
}

@Test("A minimal Project file loads with every Bound and schedule default")
func projectMinimalFileLoads() throws {
    let configuration = try ProjectConfiguration.load(contentsOf: fixture("minimal", in: "Valid"))
    let expected = ProjectConfiguration(
        id: try projectID("minimal"),
        name: "Minimal Project",
        linearProject: "MIN",
        specSource: "~/dev/minimal-spec",
        repos: [
            RepoDeclaration(
                name: "only-repo",
                path: "~/dev/minimal",
                role: .backend,
                check: .command("swift test"),
                protectedPaths: []
            )
        ],
        bounds: Bounds(),
        schedule: Schedule(),
        gitHubCredential: nil,
        routingOverrides: []
    )
    #expect(configuration == expected)
}

private let fullFixtureRepos = [
    RepoDeclaration(
        name: "backend",
        path: "~/dev/full-backend",
        role: .backend,
        check: .command("swift test"),
        protectedPaths: ["Secrets/", "Private/"]
    ),
    RepoDeclaration(
        name: "spec-repo",
        path: "~/dev/full-spec",
        role: .spec,
        check: .none,
        protectedPaths: []
    ),
    RepoDeclaration(
        name: "custom-role",
        path: "~/dev/full-custom",
        role: RepoRole(rawValue: "data-pipeline"),
        check: .command("python -m pytest"),
        protectedPaths: []
    )
]

@Test("A full Project file loads every Repo, Bound, schedule key, credential and routing override")
func projectFullFileLoads() throws {
    let configuration = try ProjectConfiguration.load(contentsOf: fixture("full", in: "Valid"))
    let expected = ProjectConfiguration(
        id: try projectID("full"),
        name: "Full Project",
        linearProject: "FULL",
        repos: fullFixtureRepos,
        bounds: Bounds(
            reviewRoundsMax: 3,
            attemptsPerCard: 5,
            unansweredNightsMax: 4,
            reselectionsMax: 3,
            consecutiveRefusalsMax: 5,
            failedAdoptionsMax: 3
        ),
        schedule: Schedule(
            nightStart: try time(hour: 23, minute: 0),
            nightEnd: try time(hour: 7, minute: 0),
            buildEveryMinutes: 20
        ),
        gitHubCredential: CredentialReference("keychain:github-full"),
        routingOverrides: [
            RoutingEntry(
                kind: try kind("impl.boilerplate"),
                repoRole: .role(.backend),
                route: try route("claude", "sonnet", "low"),
                fallbacks: []
            ),
            RoutingEntry(
                kind: try kind("review"),
                repoRole: .any,
                route: try route("claude", "opus"),
                fallbacks: [try route("codex", "gpt-5.4", "high")]
            )
        ]
    )
    #expect(configuration == expected)
}

@Test("projectRepositories carries each Repo's protected paths through to Domain")
func projectRepositoriesCarriesProtectedPaths() throws {
    let configuration = try ProjectConfiguration.load(contentsOf: fixture("full", in: "Valid"))
    let backend = try #require(configuration.repositories.workingRepo(named: "backend"))
    #expect(backend.protectedPaths == ["Secrets/", "Private/"])

    let specRepo = try #require(configuration.repositories.workingRepo(named: "spec-repo"))
    #expect(specRepo.protectedPaths == [])
}

@Test("Absent limits and schedule keys take their defaults")
func projectPartialLimitsScheduleLoads() throws {
    let configuration = try ProjectConfiguration.load(contentsOf: fixture("partial-limits-schedule", in: "Valid"))
    let expectedID = try projectID("partial-limits-schedule")
    let expectedNightStart = try time(hour: 22, minute: 0)
    let expectedNightEnd = try time(hour: 6, minute: 0)
    #expect(configuration.id == expectedID)
    #expect(configuration.bounds == Bounds(reviewRoundsMax: 4))
    #expect(configuration.schedule == Schedule(
        nightStart: expectedNightStart, nightEnd: expectedNightEnd, buildEveryMinutes: 30
    ))
}

@Test("An unreadable Project file is reported on line 1")
func projectUnreadableFile() {
    let url = URL(filePath: "/nonexistent/yellowhammer/projects/missing.toml")
    do {
        _ = try ProjectConfiguration.load(contentsOf: url)
        Issue.record("expected an error")
    } catch {
        #expect(error.file == "/nonexistent/yellowhammer/projects/missing.toml")
        #expect(error.line == 1)
        #expect(error.key == nil)
        guard case .unreadable = error.reason else {
            Issue.record("expected .unreadable, got \(error.reason)")
            return
        }
    }
}

@Test("A time of day is exactly HH:MM within range", arguments: [
    ("00:00", true), ("23:59", true), ("06:00", true),
    ("24:00", false), ("12:60", false), ("9:00", false), ("09:0", false), ("+9:00", false), ("09-00", false)
])
func timeOfDayFormat(_ string: String, valid: Bool) {
    #expect((TimeOfDay(string) != nil) == valid)
}

@Test("A Project ID is ASCII letters, digits, underscores and hyphens", arguments: [
    ("yellowhammer", true), ("Project_2-b", true), ("", false), ("a b", false), ("a/b", false), ("é", false)
])
func projectIDCharacters(_ string: String, valid: Bool) {
    #expect((ProjectID(rawValue: string) != nil) == valid)
}
