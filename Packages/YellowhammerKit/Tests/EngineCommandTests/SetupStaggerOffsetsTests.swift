import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

@Suite("yh setup: recording Stagger Offsets before generating jobs")
struct SetupStaggerOffsetsTests {
    private func projectFile(_ directory: borrowing ConfigurationDirectory, _ id: String) throws -> String {
        try String(
            contentsOf: directory.url.appending(components: "projects", "\(id).toml"), encoding: .utf8
        )
    }

    private func exportJobs(
        _ directory: borrowing ConfigurationDirectory, output: RecordingOutput = RecordingOutput()
    ) async throws -> URL {
        let board = await makeBoard()
        let exportDirectory = freshExportDirectory()
        let arguments = makeArguments(
            operatorID: "user-op", exportJobs: exportDirectory.path(percentEncoded: false), installation: "acme"
        )
        let setup = try makeSetup(arguments: arguments, directory: directory, board: board, output: output)
        try await setup.run()
        return exportDirectory
    }

    private func authorHour(_ exportDirectory: URL, _ id: String) throws -> [Int] {
        let plist = try decodePlist(at: exportDirectory.appending(component: "dev.yellowhammer.\(id).author.plist"))
        let intervals = try #require(plist["StartCalendarInterval"] as? [[String: Int]])
        return intervals.prefix(1).flatMap { [$0["Hour"] ?? -1, $0["Minute"] ?? -1] }
    }

    @Test("Setup records 0, 3, 6 for fresh Projects before generating jobs, and prints one line each")
    func recordsOffsetsBeforeGeneratingJobs() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        try directory.writeValidProjectFile(id: "beta")
        try directory.writeValidProjectFile(id: "gamma")
        let output = RecordingOutput()

        let exported = try await exportJobs(directory, output: output)

        for (id, offset) in [("alpha", 0), ("beta", 3), ("gamma", 6)] {
            let configuration = try ProjectConfiguration.parse(try projectFile(directory, id), file: id)
            #expect(configuration.schedule.staggerMinutes == offset)
            #expect(output.lines.contains("Project \(id): recorded stagger_minutes = \(offset)"))
            #expect(try authorHour(exported, id) == [22, offset])
        }
    }

    @Test("Adding a Project assigns the next free offset and moves no sibling; a rerun records nothing")
    func addingAProjectLeavesSiblingsAlone() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        for id in ["alpha", "beta", "gamma"] { try directory.writeValidProjectFile(id: id) }
        _ = try await exportJobs(directory)
        let before = try ["alpha", "beta", "gamma"].map { try projectFile(directory, $0) }

        try directory.writeValidProjectFile(id: "aardvark")
        let output = RecordingOutput()
        let exported = try await exportJobs(directory, output: output)

        #expect(try ["alpha", "beta", "gamma"].map { try projectFile(directory, $0) } == before)
        #expect(output.lines.filter { $0.contains("recorded stagger_minutes") }
            == ["Project aardvark: recorded stagger_minutes = 9"])
        #expect(try authorHour(exported, "aardvark") == [22, 9])
        #expect(try authorHour(exported, "beta") == [22, 3])

        let rerun = RecordingOutput()
        _ = try await exportJobs(directory, output: rerun)
        #expect(!rerun.lines.contains { $0.contains("recorded stagger_minutes") })
    }

    @Test("A recorded Operator value is kept, comments survive, and a freed offset is reused")
    func operatorValueAndComments() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha", stagger: 3)
        try directory.writeProjectFile(id: "beta", """
            # beta's own file
            id = "beta"
            name = "beta"
            board = { linear = { connection = "acme", project = "beta" } }
            code_hosting = { connection = "github" }
            spec_source = "~/Developer/beta-spec"

            [schedule] # the Night
            build_every_minutes = 20 # sparse

            [[repos]]
            name = "backend"
            path = "~/Developer/beta-backend"
            role = "backend"
            check = "swift test"
            """)

        _ = try await exportJobs(directory)

        let beta = try projectFile(directory, "beta")
        #expect(beta.contains("# beta's own file"))
        #expect(beta.contains("[schedule] # the Night\nbuild_every_minutes = 20 # sparse\nstagger_minutes = 0\n"))
        let alpha = try ProjectConfiguration.parse(try projectFile(directory, "alpha"), file: "a")
        #expect(alpha.schedule.staggerMinutes == 3)
    }

    @Test("An offset past the window assigns nothing, writes nothing and fails setup; siblings are scheduled")
    func overWindowIsRefused() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        func short(_ id: String) -> String {
            """
            id = "\(id)"
            name = "\(id)"
            board = { linear = { connection = "acme", project = "\(id)" } }
            code_hosting = { connection = "github" }
            spec_source = "~/Developer/\(id)-spec"

            [schedule]
            night_start = "01:00"
            night_end = "01:05"

            [[repos]]
            name = "backend"
            path = "~/Developer/\(id)-backend"
            role = "backend"
            check = "swift test"
            """
        }
        for id in ["a", "b", "c"] { try directory.writeProjectFile(id: id, short(id)) }
        try directory.writeValidProjectFile(id: "d")
        let output = RecordingOutput()
        let exportDirectory = freshExportDirectory()
        let setup = try makeSetup(
            arguments: makeArguments(
                operatorID: "user-op", exportJobs: exportDirectory.path(percentEncoded: false), installation: "acme"
            ),
            directory: directory, board: await makeBoard(), output: output
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(try projectFile(directory, "c") == short("c"))
        #expect(output.lines.contains { $0.contains("Project c:") && $0.contains("6") && $0.contains("5-minute") })
        let files = try FileManager.default.contentsOfDirectory(atPath: exportDirectory.path(percentEncoded: false))
        #expect(files.contains("dev.yellowhammer.a.author.plist"))
        #expect(files.contains("dev.yellowhammer.d.author.plist"))
        #expect(!files.contains { $0.contains(".c.") })
        let delta = try ProjectConfiguration.parse(try projectFile(directory, "d"), file: "d")
        #expect(delta.schedule.staggerMinutes == 6)
    }
}
