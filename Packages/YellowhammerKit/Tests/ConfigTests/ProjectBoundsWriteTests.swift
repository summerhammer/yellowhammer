import Config
import Domain
import Foundation
import Testing

/// The path the app's Settings save takes to write the Bounds after `yh setup --init`.
@Suite("Project Bounds write")
struct ProjectBoundsWriteTests {
    private func changedBounds() -> Bounds {
        Bounds(reviewRoundsMax: 4, attemptsPerWorkCard: 5)
    }

    @Test("Changed Bounds are saved and reload")
    func writesBounds() throws {
        let project = try testEditingProject(id: "acme")
        let directory = try makeEditingDirectory(machine: try testEditingMachine(), projects: [project])
        defer { cleanupEditingDirectory(directory) }
        let file = editingProjectFileURL(directory, "acme")
        let original = try String(contentsOf: file, encoding: .utf8)

        let loaded = try #require(try Configuration.load(directory: directory).projects.first)
        var draft = ProjectFileDraft(loaded)
        draft.bounds = BoundsDraft(changedBounds())
        try Configuration.save(draft.renderedTOML, to: file, in: directory, replacing: original)

        let reloaded = try #require(try Configuration.load(directory: directory).projects.first)
        #expect(reloaded.bounds == changedBounds())
    }

    @Test("A Bound of 0 is refused and the Project keeps its text and default Bounds")
    func refusesZero() throws {
        let project = try testEditingProject(id: "acme")
        let directory = try makeEditingDirectory(machine: try testEditingMachine(), projects: [project])
        defer { cleanupEditingDirectory(directory) }
        let file = editingProjectFileURL(directory, "acme")
        let original = try String(contentsOf: file, encoding: .utf8)

        var draft = ProjectFileDraft(project)
        draft.bounds = BoundsDraft(Bounds(attemptsPerWorkCard: 0))
        #expect(throws: ConfigurationEditError.self) {
            try Configuration.save(draft.renderedTOML, to: file, in: directory, replacing: original)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
        let reloaded = try #require(try Configuration.load(directory: directory).projects.first)
        #expect(reloaded.bounds == Bounds())
    }

    @Test("A concurrent edit refuses the write and leaves the file as it was")
    func refusesStaleText() throws {
        let project = try testEditingProject(id: "acme")
        let directory = try makeEditingDirectory(machine: try testEditingMachine(), projects: [project])
        defer { cleanupEditingDirectory(directory) }
        let file = editingProjectFileURL(directory, "acme")
        let current = try String(contentsOf: file, encoding: .utf8)

        var draft = ProjectFileDraft(project)
        draft.bounds = BoundsDraft(changedBounds())
        #expect(throws: ConfigurationEditError.self) {
            try Configuration.save(
                draft.renderedTOML, to: file, in: directory, replacing: current + "# edited elsewhere\n"
            )
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == current)
        let reloaded = try #require(try Configuration.load(directory: directory).projects.first)
        #expect(reloaded.bounds == Bounds())
    }
}
