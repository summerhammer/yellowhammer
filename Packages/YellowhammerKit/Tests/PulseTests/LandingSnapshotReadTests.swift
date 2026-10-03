import Config
import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

private let machineTOML = """
[board.linear.installations.acme]
credential = "keychain:linear"
workspace = "workspace-1"
app_user = "app-user-1"
[github]
credential = "keychain:github"

[cli.claude]

[[routing]]
route = "claude/sonnet"
"""

/// A throwaway configuration directory: machine file, Project files and Journals. Removed on deinit, so a
/// test creates it in its own body: a helper returning it would delete the directory under the caller.
private struct ConfigurationFixture: ~Copyable {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-landing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory.appending(component: "projects", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try machineTOML.write(to: directory.appending(component: "config.toml"), atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func addProject(id: String, name: String, repos: [String], sharedRepoPath: String? = nil) throws {
        var toml = """
        id = "\(id)"
        name = "\(name)"
        board = { linear = { installation = "acme", project = "\(id.uppercased())" } }
        spec_source = "~/dev/spec"

        """
        for repo in repos {
            toml += """

            [[repos]]
            name = "\(repo)"
            path = "\(sharedRepoPath ?? "~/dev/\(id)-\(repo)")"
            role = "\(repo)"
            check = "swift test"

            """
        }
        try toml.write(
            to: directory.appending(components: "projects", "\(id).toml", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )
    }

    func load() throws -> Configuration {
        let configuration = try Configuration.load(directory: directory)
        try #require(configuration.invalidProjects.isEmpty)
        return configuration
    }

    func addRawProjectFile(id: String, contents: String) throws {
        try contents.write(
            to: directory.appending(components: "projects", "\(id).toml", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )
    }

    func read(_ configuration: Configuration, asOf: Date) -> LandingSnapshot {
        LandingSnapshot.read(configuration: configuration, configurationDirectory: directory, asOf: asOf)
    }

    func journalURL(_ id: String) throws -> URL {
        JournalStore.defaultFileURL(configurationDirectory: directory, id: try #require(ProjectID(rawValue: id)))
    }

    func openJournal(_ id: String) throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: id)))
    }
}

@Test("The landing read lists the configured Projects in loader order with names and declared Repo order")
func landingListsConfiguredProjects() throws {
    let fixture = try ConfigurationFixture()
    try fixture.addProject(id: "beta", name: "Beta", repos: ["web", "api"])
    try fixture.addProject(id: "alpha", name: "Alpha", repos: ["mobile", "backend", "shared"])
    let configuration = try fixture.load()

    let landing = fixture.read(configuration, asOf: epoch)

    #expect(landing.projects.map(\.id.rawValue) == configuration.projects.map(\.id.rawValue))
    #expect(landing.projects.map(\.id.rawValue) == ["alpha", "beta"])
    #expect(landing.projects.map(\.name) == ["Alpha", "Beta"])
    #expect(landing.projects[0].repos == ["mobile", "backend", "shared"])
    #expect(landing.projects[1].repos == ["web", "api"])
}

@Test("A Project with no Journal reads as the empty idle Pulse and no Journal is created")
func landingMissingJournal() throws {
    let fixture = try ConfigurationFixture()
    try fixture.addProject(id: "alpha", name: "Alpha", repos: ["backend"])
    let configuration = try fixture.load()

    let landing = fixture.read(configuration, asOf: epoch)

    let alpha = try #require(landing.projects.first)
    #expect(alpha.pulse == PulseSnapshot.empty)
    #expect(alpha.journalFailure == nil)
    #expect(alpha.status == .idle)
    #expect(!FileManager.default.fileExists(atPath: try fixture.journalURL("alpha").path))
}

@Test("An unreadable Journal is that Project's failure and leaves its sibling unchanged")
func landingUnreadableJournal() throws {
    let fixture = try ConfigurationFixture()
    try fixture.addProject(id: "alpha", name: "Alpha", repos: ["backend"])
    try fixture.addProject(id: "beta", name: "Beta", repos: ["web"])
    let configuration = try fixture.load()
    try FileManager.default.createDirectory(
        at: try fixture.journalURL("alpha").deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data().write(to: try fixture.journalURL("alpha"))

    let landing = fixture.read(configuration, asOf: epoch)

    let alpha = try #require(landing.project(ProjectID(rawValue: "alpha")))
    let beta = try #require(landing.project(ProjectID(rawValue: "beta")))
    #expect(alpha.journalFailure != nil)
    #expect(alpha.pulse == PulseSnapshot.empty)
    #expect(beta.journalFailure == nil)
    #expect(beta.pulse == PulseSnapshot.empty)
}

@Test("A seeded Journal reads into the Project's Pulse, and asOf is carried through")
func landingSeededJournal() throws {
    let fixture = try ConfigurationFixture()
    try fixture.addProject(id: "alpha", name: "Alpha", repos: ["backend"])
    try fixture.addProject(id: "beta", name: "Beta", repos: ["web"])
    let configuration = try fixture.load()
    let asOf = epoch.addingTimeInterval(60)
    let expected: PulseSnapshot
    do {
        let journal = try fixture.openJournal("alpha")
        let feature = try insertFeature(journal, issueID: "ALPHA-F")
        try insertCard(
            journal, cycleID: feature.cycleID, issueID: "ALPHA-1",
            repository: "backend", state: .blocked, blockReason: .hardFailure
        )
        _ = try journal.claimActLease(act: .build, runID: RunID(), mode: .real, now: epoch)
        expected = try PulseSnapshot.read(from: journal, asOf: asOf)
    }

    let landing = fixture.read(configuration, asOf: asOf)

    let alpha = try #require(landing.project(ProjectID(rawValue: "alpha")))
    #expect(expected.now.status == .working)
    #expect(expected.needsYou.cards.map(\.id) == ["ALPHA-1"])
    #expect(expected.feature?.id == "ALPHA-F")
    #expect(alpha.pulse == expected)
    #expect(alpha.journalFailure == nil)
    #expect(alpha.status == .working)
    #expect(landing.asOf == asOf)
    let beta = try #require(landing.project(ProjectID(rawValue: "beta")))
    #expect(beta.pulse == PulseSnapshot.empty)
}

/// Alpha: a Feature, a Blocked Card, and a Card with a running Attempt. No Act Lease is left held.
private func seedBlendingAlpha(_ journal: JournalStore) throws {
    let feature = try insertFeature(journal, issueID: "ALPHA-F")
    try insertCard(
        journal, cycleID: feature.cycleID, issueID: "ALPHA-1",
        repository: "backend", state: .blocked, blockReason: .hardFailure, order: 1
    )
    let running = try insertCard(
        journal, cycleID: feature.cycleID, issueID: "ALPHA-2",
        repository: "backend", state: .inProgress, order: 2
    )
    let run = RunID()
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
    _ = try journal.recordAttempt(cardID: running, route: route(), runID: run, now: epoch)
    _ = try journal.releaseActLease(runID: run)
}

/// Beta: a Feature, a Waiting on You Card, a held Act Lease and an opened Night.
private func seedBlendingBeta(_ journal: JournalStore) throws {
    let feature = try insertFeature(journal, issueID: "BETA-F")
    try insertCard(journal, cycleID: feature.cycleID, issueID: "BETA-1", repository: "api", state: .waitingOnYou)
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
    _ = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)
}

@Test("No element of the landing snapshot blends two Projects' data")
func landingBlendsNothing() throws {
    let fixture = try ConfigurationFixture()
    try fixture.addProject(id: "alpha", name: "Alpha", repos: ["backend", "web"])
    try fixture.addProject(id: "beta", name: "Beta", repos: ["api"])
    let configuration = try fixture.load()
    let expectedAlpha: PulseSnapshot
    let expectedBeta: PulseSnapshot
    do {
        let journal = try fixture.openJournal("alpha")
        try seedBlendingAlpha(journal)
        expectedAlpha = try PulseSnapshot.read(from: journal, asOf: epoch)
    }
    do {
        let journal = try fixture.openJournal("beta")
        try seedBlendingBeta(journal)
        expectedBeta = try PulseSnapshot.read(from: journal, asOf: epoch)
    }

    let landing = fixture.read(configuration, asOf: epoch)

    let alpha = try #require(landing.project(ProjectID(rawValue: "alpha")))
    let beta = try #require(landing.project(ProjectID(rawValue: "beta")))
    #expect(alpha.pulse == expectedAlpha)
    #expect(beta.pulse == expectedBeta)
    #expect(alpha.repos == ["backend", "web"])
    #expect(beta.repos == ["api"])
    #expect(alpha.status == .idle)
    #expect(beta.status == .working)
    #expect(alpha.runningAttempt(for: "backend") != nil)
    #expect(beta.runningAttempt(for: "backend") == nil)
    let alphaAttempt = try #require(alpha.runningAttempt(for: "backend"))
    #expect(alpha.runningAttempt(id: alphaAttempt.id) == alphaAttempt)
    #expect(beta.runningAttempt(id: alphaAttempt.id) == nil)
    #expect(alpha.laneState(for: "api") == nil)
    #expect(beta.laneState(for: "backend") == nil)
    #expect(!alpha.contains(.card("BETA-1")))
    #expect(!beta.contains(.card("ALPHA-1")))
    #expect(!beta.contains(.repo("backend")))
    #expect(!alpha.contains(.feature("BETA-F")))

    #expect(!alpha.pulse.now.attempts.isEmpty)
    for (snapshot, prefix) in [(alpha, "ALPHA-"), (beta, "BETA-")] {
        let cards = snapshot.pulse.needsYou.cards
        let attempts = snapshot.pulse.now.attempts
        let feature = try #require(snapshot.pulse.feature)
        #expect(!cards.isEmpty)
        #expect(cards.allSatisfy { $0.id.hasPrefix(prefix) })
        #expect(attempts.allSatisfy { $0.cardID.hasPrefix(prefix) })
        #expect(feature.id.hasPrefix(prefix))
        #expect(feature.lanes.allSatisfy { snapshot.repos.contains($0.repo) })
    }
}

@Test("A refused Project is absent from the landing snapshot, and its Journal is never read")
func landingOmitsRefusedProjects() throws {
    let fixture = try ConfigurationFixture()
    try fixture.addProject(id: "alpha", name: "Alpha", repos: ["backend"])
    try fixture.addRawProjectFile(id: "broken", contents: """
        id = "broken"
        name = "Broken"

        [[repos
        """)
    try fixture.addProject(id: "clash-a", name: "Clash A", repos: ["backend"], sharedRepoPath: "~/dev/clash")
    try fixture.addProject(id: "clash-b", name: "Clash B", repos: ["backend"], sharedRepoPath: "~/dev/clash")
    for id in ["broken", "clash-a"] {
        let journal = try fixture.openJournal(id)
        let feature = try insertFeature(journal, issueID: "REFUSED-F")
        try insertCard(
            journal, cycleID: feature.cycleID, issueID: "REFUSED-1",
            state: .blocked, blockReason: .hardFailure
        )
        _ = try journal.claimActLease(act: .build, runID: RunID(), mode: .real, now: epoch)
    }
    let configuration = try Configuration.load(directory: fixture.directory)
    try #require(configuration.invalidProjects.count == 3)
    try #require(configuration.projects.map(\.id.rawValue) == ["alpha"])

    let landing = fixture.read(configuration, asOf: epoch)

    #expect(landing.projects.map(\.id.rawValue) == ["alpha"])
    #expect(landing.projects.allSatisfy { !["Broken", "Clash A", "Clash B"].contains($0.name) })
    #expect(!landing.projects.contains { $0.pulse.needsYou.cards.contains { $0.id == "REFUSED-1" } })
    #expect(landing.projects.first?.status == .idle)
}

@Test("A Project contains its own Card, Feature, running Attempt and Repo, and nothing else")
func projectContainsSelection() throws {
    var pulse = PulseSnapshot.empty
    pulse.needsYou = NeedsYou(cards: [
        DecisionCard(id: "C-1", title: "Card", state: .blocked, blockReason: .hardFailure, repo: "backend")
    ])
    pulse.now = Now(
        status: .working,
        nextAct: nil,
        attempts: [
            RunningAttempt(
                id: "attempt-1", cardID: "C-2", cardTitle: "Other", repo: "backend",
                route: "claude/sonnet/medium", startedAt: epoch, round: 1, status: nil
            )
        ]
    )
    pulse.feature = FeatureInFlight(id: "F-1", title: nil, state: nil, rollupState: nil, lanes: [])
    let alpha = ProjectSnapshot(
        id: try #require(ProjectID(rawValue: "alpha")), name: "Alpha", repos: ["backend", "web"], pulse: pulse
    )

    #expect(alpha.contains(.card("C-1")))
    #expect(alpha.contains(.feature("F-1")))
    #expect(alpha.contains(.attempt("attempt-1")))
    #expect(alpha.contains(.repo("backend")))
    #expect(alpha.contains(.repo("web")))
    #expect(!alpha.contains(.card("C-9")))
    #expect(!alpha.contains(.feature("F-9")))
    #expect(!alpha.contains(.attempt("attempt-9")))
    #expect(!alpha.contains(.repo("mobile")))
}

@Test("A schema-1 Journal is that Project's failure: the app refuses a Journal older than this build")
func landingSchemaOneJournal() throws {
    let fixture = try ConfigurationFixture()
    try fixture.addProject(id: "alpha", name: "Alpha", repos: ["backend"])
    let configuration = try fixture.load()
    // Scoped, so the writer is gone before the app's read-only open.
    do {
        let journal = try fixture.openJournal("alpha")
        try journal.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations")
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('journal-schema-1')")
        }
    }

    let landing = fixture.read(configuration, asOf: epoch)

    let alpha = try #require(landing.projects.first)
    #expect(alpha.journalFailure?.contains("created by an earlier build") == true)
}
