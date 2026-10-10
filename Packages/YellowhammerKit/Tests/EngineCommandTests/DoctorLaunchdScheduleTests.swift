import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

/// How a hand-edited plist departs from the firings its `[schedule]` implies: the shape of a job installed
/// before the build offset or the flush firings existed.
enum ScheduleEdit: CaseIterable {
    case moved
    case removed
    case added
}

private let yhPath = "/opt/yellowhammer/yh"

private func temporaryHome() throws -> (home: URL, agents: URL) {
    let home = FileManager.default.temporaryDirectory
        .appending(component: "yh-doctor-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    let agents = home.appending(components: "Library", "LaunchAgents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    return (home, agents)
}

private func projectID(_ id: String) throws -> ProjectID {
    try #require(ProjectID(rawValue: id))
}

/// What the default `[schedule]` implies for the Project at `staggerIndex` — the same call doctor makes.
private func expectedFirings(_ act: Act, staggerIndex: Int) throws -> [TimeOfDay] {
    let firings = try Schedule().firings(staggerIndex: staggerIndex)
    switch act {
    case .author: return firings.author
    case .build: return firings.build
    case .land: return firings.land
    }
}

private func label(_ project: String, _ act: Act) throws -> String {
    act.launchdLabel(projectID: try projectID(project))
}

@discardableResult
private func writePlist(
    project: String, act: Act, firings: [TimeOfDay], in agents: URL
) throws -> URL {
    let job = ScheduledJob(
        projectID: try projectID(project), act: act, yhExecutablePath: yhPath, firings: firings,
        pathValue: "/usr/bin:/bin"
    )
    let url = agents.appending(component: job.fileName, directoryHint: .notDirectory)
    try job.plistData(homeDirectory: "/Users/test").write(to: url)
    return url
}

/// Installs every Act's plist for `project` as `firings(staggerIndex:)` returns it.
private func writeMatchingPlists(project: String, staggerIndex: Int, in agents: URL) throws {
    for act in Act.allCases {
        try writePlist(
            project: project, act: act, firings: try expectedFirings(act, staggerIndex: staggerIndex), in: agents
        )
    }
}

/// A time of day that is not among `times`.
private func timeAbsent(from times: [TimeOfDay]) throws -> TimeOfDay {
    let taken = Set(times)
    let candidates = (0..<1440).compactMap { TimeOfDay(hour: $0 / 60, minute: $0 % 60) }
    return try #require(candidates.first { !taken.contains($0) })
}

private func edited(_ firings: [TimeOfDay], _ edit: ScheduleEdit) throws -> [TimeOfDay] {
    switch edit {
    case .moved: [try timeAbsent(from: firings)] + firings.dropFirst()
    case .removed: Array(firings.dropFirst())
    case .added: firings + [try timeAbsent(from: firings)]
    }
}

private func launchdFindings(_ findings: [DoctorFinding]) -> [DoctorFinding] {
    findings.filter { $0.check == .launchd && $0.projectID != nil }
}

private func twoProjectDirectory() throws -> ConfigurationDirectory {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    try directory.writeValidProjectFile(id: "beta")
    return directory
}

@Suite("Doctor: launchd schedule check")
struct DoctorLaunchdScheduleTests {
    @Test("Plists generated from firings() pass, each Project at its own stagger index")
    func matchingPlistsPass() async throws {
        let directory = try twoProjectDirectory()
        let (home, agents) = try temporaryHome()
        try writeMatchingPlists(project: "alpha", staggerIndex: 0, in: agents)
        try writeMatchingPlists(project: "beta", staggerIndex: 1, in: agents)
        let loaded = try Set(Act.allCases.flatMap { act in [try label("alpha", act), try label("beta", act)] })

        let findings = await makeDoctor(
            directory: directory, homeDirectory: home, launchAgents: RecordingLaunchAgentControl(loadedLabels: loaded),
            checks: [.configuration, .launchd]
        ).run()

        let launchd = launchdFindings(findings)
        #expect(launchd.count == 6)
        #expect(launchd.allSatisfy { $0.severity == .pass })
    }

    @Test("A StartCalendarInterval written as a single dictionary is read as one firing")
    func singleDictionaryIsAccepted() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let (home, agents) = try temporaryHome()
        try writeMatchingPlists(project: "alpha", staggerIndex: 0, in: agents)
        let author = try #require(try expectedFirings(.author, staggerIndex: 0).first)
        let plist: [String: Any] = [
            "Label": try label("alpha", .author),
            "StartCalendarInterval": ["Hour": author.hour, "Minute": author.minute]
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: agents.appending(component: "\(try label("alpha", .author)).plist"))
        let loaded = try Set(Act.allCases.map { try label("alpha", $0) })

        let findings = await makeDoctor(
            directory: directory, homeDirectory: home, launchAgents: RecordingLaunchAgentControl(loadedLabels: loaded),
            checks: [.configuration, .launchd]
        ).run()

        #expect(launchdFindings(findings).allSatisfy { $0.severity == .pass })
    }

    @Test("A plist edited to differ from firings() warns, naming the Project and Act and advising --fix",
          arguments: Act.allCases, ScheduleEdit.allCases)
    func differingPlistWarns(act: Act, edit: ScheduleEdit) async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let (home, agents) = try temporaryHome()
        try writeMatchingPlists(project: "alpha", staggerIndex: 0, in: agents)
        try writePlist(
            project: "alpha", act: act, firings: try edited(try expectedFirings(act, staggerIndex: 0), edit),
            in: agents
        )
        let loaded = try Set(Act.allCases.map { try label("alpha", $0) })

        let findings = await makeDoctor(
            directory: directory, homeDirectory: home, launchAgents: RecordingLaunchAgentControl(loadedLabels: loaded),
            checks: [.configuration, .launchd]
        ).run()

        let differing = try label("alpha", act)
        let warning = try #require(findings.first { $0.check == .launchd && $0.subject == differing })
        #expect(warning.severity == .warning)
        #expect(warning.projectID == (try projectID("alpha")))
        #expect(warning.message.contains("Project alpha \(act.rawValue)"))
        #expect(warning.message.contains("yh doctor --fix"))
        let others = launchdFindings(findings).filter { $0.subject != differing }
        #expect(others.count == 2)
        #expect(others.allSatisfy { $0.severity == .pass })
    }

    @Test("A plist with no readable firings warns")
    func unreadablePlistWarns() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let (home, agents) = try temporaryHome()
        let authorLabel = try label("alpha", .author)
        try Data().write(to: agents.appending(component: "\(authorLabel).plist"))

        let findings = await makeDoctor(
            directory: directory, homeDirectory: home,
            launchAgents: RecordingLaunchAgentControl(loadedLabels: [authorLabel]),
            checks: [.configuration, .launchd]
        ).run()

        let finding = try #require(findings.first { $0.check == .launchd && $0.subject == authorLabel })
        #expect(finding.severity == .warning)
        #expect(finding.message.contains("could not be read"))
    }

    @Test("--fix rewrites a differing job so a second run passes")
    func fixRewritesDifferingJobs() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let (home, agents) = try temporaryHome()
        try writeMatchingPlists(project: "alpha", staggerIndex: 0, in: agents)
        let buildLabel = try label("alpha", .build)
        let buildFirings = try expectedFirings(.build, staggerIndex: 0)
        try writePlist(
            project: "alpha", act: .build, firings: try edited(buildFirings, .moved), in: agents
        )
        let loaded = try Set(Act.allCases.map { try label("alpha", $0) })
        let control = RecordingLaunchAgentControl(loadedLabels: loaded)

        let fixed = await makeDoctor(
            directory: directory, homeDirectory: home, launchAgents: control,
            fix: true, checks: [.configuration, .launchd], runningExecutablePath: yhPath
        ).run()

        let finding = try #require(fixed.first { $0.check == .launchd && $0.subject == buildLabel })
        #expect(finding.severity == .pass)
        #expect(finding.message.contains("regenerated"))
        #expect(control.calls.contains(.bootout(buildLabel)))
        #expect(control.calls.contains(.bootstrap(buildLabel)))

        let second = await makeDoctor(
            directory: directory, homeDirectory: home, launchAgents: RecordingLaunchAgentControl(loadedLabels: loaded),
            checks: [.configuration, .launchd], runningExecutablePath: yhPath
        ).run()
        let launchd = launchdFindings(second)
        #expect(launchd.count == 3)
        #expect(launchd.allSatisfy { $0.severity == .pass })
    }

    @Test("--fix leaves a matching sibling Project's plists byte-identical")
    func fixLeavesMatchingSiblingUntouched() async throws {
        let directory = try twoProjectDirectory()
        let (home, agents) = try temporaryHome()
        try writeMatchingPlists(project: "alpha", staggerIndex: 0, in: agents)
        try writeMatchingPlists(project: "beta", staggerIndex: 1, in: agents)
        try writePlist(
            project: "alpha", act: .land,
            firings: try edited(try expectedFirings(.land, staggerIndex: 0), .removed), in: agents
        )
        let betaURLs = try Act.allCases.map { agents.appending(component: "\(try label("beta", $0)).plist") }
        let before = try betaURLs.map { try Data(contentsOf: $0) }
        let loaded = try Set(Act.allCases.flatMap { act in [try label("alpha", act), try label("beta", act)] })
        let control = RecordingLaunchAgentControl(loadedLabels: loaded)

        let findings = await makeDoctor(
            directory: directory, homeDirectory: home, launchAgents: control,
            fix: true, checks: [.configuration, .launchd]
        ).run()

        #expect(try betaURLs.map { try Data(contentsOf: $0) } == before)
        #expect(!control.calls.contains { call in
            if case .bootstrap(let name) = call { return name.contains(".beta.") }
            return false
        })
        #expect(launchdFindings(findings).allSatisfy { $0.severity == .pass })
    }

    @Test("--fix under a Project filter leaves even a differing sibling Project alone")
    func fixRespectsProjectFilter() async throws {
        let directory = try twoProjectDirectory()
        let (home, agents) = try temporaryHome()
        for (project, index) in [("alpha", 0), ("beta", 1)] {
            try writeMatchingPlists(project: project, staggerIndex: index, in: agents)
            try writePlist(
                project: project, act: .build,
                firings: try edited(try expectedFirings(.build, staggerIndex: index), .added), in: agents
            )
        }
        let betaBuild = agents.appending(component: "\(try label("beta", .build)).plist")
        let before = try Data(contentsOf: betaBuild)
        let loaded = try Set(Act.allCases.flatMap { act in [try label("alpha", act), try label("beta", act)] })

        let findings = await makeDoctor(
            directory: directory, homeDirectory: home, launchAgents: RecordingLaunchAgentControl(loadedLabels: loaded),
            fix: true, checks: [.configuration, .launchd], projectFilter: try projectID("alpha")
        ).run()

        #expect(try Data(contentsOf: betaBuild) == before)
        #expect(findings.allSatisfy { $0.projectID != (try? projectID("beta")) })
        #expect(launchdFindings(findings).allSatisfy { $0.severity == .pass })
    }

    @Test("The stagger index does not depend on which Project the filter names")
    func filterKeepsTheStaggerIndex() async throws {
        let directory = try twoProjectDirectory()
        let (home, agents) = try temporaryHome()
        try writeMatchingPlists(project: "beta", staggerIndex: 1, in: agents)
        let loaded = try Set(Act.allCases.map { try label("beta", $0) })

        let findings = await makeDoctor(
            directory: directory, homeDirectory: home, launchAgents: RecordingLaunchAgentControl(loadedLabels: loaded),
            checks: [.configuration, .launchd], projectFilter: try projectID("beta")
        ).run()

        let launchd = launchdFindings(findings)
        #expect(launchd.count == 3)
        #expect(launchd.allSatisfy { $0.severity == .pass })
    }

    @Test("--fix rewrites an unloaded job's plist and leaves it unloaded")
    func fixKeepsUnloadedJobUnloaded() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let (home, agents) = try temporaryHome()
        try writeMatchingPlists(project: "alpha", staggerIndex: 0, in: agents)
        let buildFirings = try expectedFirings(.build, staggerIndex: 0)
        let buildURL = try writePlist(
            project: "alpha", act: .build, firings: try edited(buildFirings, .removed), in: agents
        )
        let buildLabel = try label("alpha", .build)
        let loaded = try Set([Act.author, .land].map { try label("alpha", $0) })
        let control = RecordingLaunchAgentControl(loadedLabels: loaded)

        let findings = await makeDoctor(
            directory: directory, homeDirectory: home, launchAgents: control,
            fix: true, checks: [.configuration, .launchd]
        ).run()

        let installed = try #require(Doctor.installedFirings(in: try Data(contentsOf: buildURL)))
        #expect(installed == Set(buildFirings))
        #expect(!control.calls.contains { call in
            switch call {
            case .bootout(let name), .enable(let name), .bootstrap(let name): name == buildLabel
            }
        })
        let buildFindings = findings.filter { $0.check == .launchd && $0.subject == buildLabel }
        #expect(buildFindings.first?.severity == .warning)
        #expect(buildFindings.first?.message.contains("not loaded") == true)
        #expect(buildFindings.contains { $0.severity == .pass && $0.message.contains("left unloaded") })
        #expect(!buildFindings.contains { $0.message.contains("differs") })
    }

    @Test("A not-installed job stays absent under --fix")
    func fixDoesNotInstallMissingJobs() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let (home, agents) = try temporaryHome()
        try writePlist(
            project: "alpha", act: .build,
            firings: try edited(try expectedFirings(.build, staggerIndex: 0), .added), in: agents
        )

        let findings = await makeDoctor(
            directory: directory, homeDirectory: home, launchAgents: RecordingLaunchAgentControl(),
            fix: true, checks: [.configuration, .launchd]
        ).run()

        let authorPlist = agents.appending(component: "\(try label("alpha", .author)).plist")
        #expect(!FileManager.default.fileExists(atPath: authorPlist.path(percentEncoded: false)))
        let author = try #require(findings.first { $0.subject == (try? label("alpha", .author)) })
        #expect(author.severity == .warning)
        #expect(author.message.contains("not installed"))
    }

    @Test("A [schedule] the grid refuses warns, naming the error, and never crashes")
    func refusedScheduleWarns() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeProjectFile(id: "alpha", """
            id = "alpha"
            name = "alpha"
            board = { linear = { connection = "acme", project = "alpha" } }
            code_hosting = { connection = "github" }
            spec_source = "~/Developer/alpha-spec"

            [schedule]
            night_start = "22:00"
            night_end = "22:00"

            [[repos]]
            name = "backend"
            path = "~/Developer/alpha-backend"
            role = "backend"
            check = "swift test"
            """)
        let (home, _) = try temporaryHome()

        let findings = await makeDoctor(
            directory: directory, homeDirectory: home, fix: true, checks: [.configuration, .launchd]
        ).run()

        let refusal = try #require(findings.first { $0.message.contains("cannot be scheduled") })
        #expect(refusal.severity == .warning)
        #expect(refusal.message.contains("24-hour Night window"))
    }
}
