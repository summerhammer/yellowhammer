import Config
import Domain
import Foundation
import Testing

/// Round trips and successful edits through ``Configuration/save(_:to:in:replacing:)`` and
/// ``Configuration/load(directory:reading:as:)``. Refusals live in ``ConfigurationEditingRefusalTests``.
@Suite("Configuration editing")
struct ConfigurationEditingTests {
    // MARK: - Round trip

    @Test("A Project draft's renderedTOML round-trips through save and reload")
    func projectDraftRoundTrips() throws {
        let machine = try testEditingMachine()
        let project = try testEditingProject(id: "roundtrip")
        let directory = try makeEditingDirectory(machine: machine, projects: [project])
        defer { cleanupEditingDirectory(directory) }

        let file = editingProjectFileURL(directory, "roundtrip")
        let originalText = try String(contentsOf: file, encoding: .utf8)
        let newText = ProjectFileDraft(project).renderedTOML

        try Configuration.save(newText, to: file, in: directory, replacing: originalText)

        let configuration = try Configuration.load(directory: directory)
        #expect(configuration.projects == [project])
    }

    @Test("The machine file's renderedTOML(routingTable:) round-trips through save and reload")
    func machineDraftRoundTrips() throws {
        let machine = try testEditingMachine()
        let directory = try makeEditingDirectory(machine: machine, projects: [])
        defer { cleanupEditingDirectory(directory) }

        let file = editingMachineFileURL(directory)
        let originalText = try String(contentsOf: file, encoding: .utf8)
        let newText = machine.renderedTOML(routingTable: machine.routingTable.map(RoutingEntryDraft.init))

        try Configuration.save(newText, to: file, in: directory, replacing: originalText)

        let configuration = try Configuration.load(directory: directory)
        #expect(configuration.machine == machine)
    }

    // MARK: - Edits round-trip through the loader

    @Test("Editing name, linear project, adding a Repo, a Bound and a routing override round-trips")
    func projectEditRoundTrips() throws {
        let machine = try testEditingMachine()
        let project = try testEditingProject(id: "editme")
        let directory = try makeEditingDirectory(machine: machine, projects: [project])
        defer { cleanupEditingDirectory(directory) }

        let file = editingProjectFileURL(directory, "editme")
        let originalText = try String(contentsOf: file, encoding: .utf8)

        var draft = ProjectFileDraft(project)
        draft.name = "Edited Name"
        draft.linearProject = "EDITED"
        draft.repos.append(
            RepoDraft(
                name: "extra", path: "~/dev/editme-extra", role: "mobile", check: "swift test",
                protectedPaths: ["Secrets/"]
            )
        )
        draft.bounds.reviewRoundsMax = "5"
        draft.routingOverrides.append(
            RoutingEntryDraft(
                kind: "impl.boilerplate",
                repoRole: "backend",
                route: RouteDraft(cli: "claude", model: "sonnet", effort: "low"),
                fallbacks: [RouteDraft(cli: "codex", model: "gpt-5.4", effort: "high")]
            )
        )

        try Configuration.save(draft.renderedTOML, to: file, in: directory, replacing: originalText)

        let configuration = try Configuration.load(directory: directory)
        let reloaded = try #require(configuration.projects.first)

        let expected = ProjectConfiguration(
            id: try editingProjectID("editme"),
            name: "Edited Name",
            linearProject: "EDITED",
            specSource: "~/dev/editme-spec",
            repos: [
                RepoDeclaration(name: "backend", path: "~/dev/editme-backend", role: .backend, check: .none),
                RepoDeclaration(
                    name: "extra", path: "~/dev/editme-extra", role: .mobile, check: .command("swift test"),
                    protectedPaths: ["Secrets/"]
                )
            ],
            bounds: Bounds(reviewRoundsMax: 5),
            routingOverrides: [
                RoutingEntry(
                    kind: try editingKind("impl.boilerplate"),
                    repoRole: .role(.backend),
                    route: try editingRoute("claude", "sonnet", "low"),
                    fallbacks: [try editingRoute("codex", "gpt-5.4", "high")]
                )
            ]
        )
        #expect(reloaded == expected)
    }

    @Test("Adding and removing a base Routing Table entry reflects in the merged table")
    func machineRoutingTableEditRoundTrips() throws {
        let machine = try testEditingMachine()
        let project = try testEditingProject(id: "consumer")
        let directory = try makeEditingDirectory(machine: machine, projects: [project])
        defer { cleanupEditingDirectory(directory) }

        let file = editingMachineFileURL(directory)
        let originalText = try String(contentsOf: file, encoding: .utf8)

        var routingTable = machine.routingTable.map(RoutingEntryDraft.init)
        routingTable.removeAll { $0.route.model == "sonnet" }
        routingTable.append(RoutingEntryDraft(route: RouteDraft(cli: "codex", model: "gpt-5.4", effort: "high")))
        let newText = machine.renderedTOML(routingTable: routingTable)

        try Configuration.save(newText, to: file, in: directory, replacing: originalText)

        let configuration = try Configuration.load(directory: directory)
        let table = try #require(configuration.routingTable(for: editingProjectID("consumer")))
        #expect(table.entries.map(\.route) == [try editingRoute("codex", "gpt-5.4", "high")])
    }

    // MARK: - Route rendering with a "/" in a part

    @Test("A route with a / in the model renders as an inline table and round-trips")
    func routeWithSlashRendersAsInlineTable() throws {
        let machine = try testEditingMachine(cliAdapters: ["claude", "codex", "openrouter"])
        let project = try testEditingProject(
            id: "slashroute",
            routingOverrides: [
                RoutingEntry(route: try editingRoute("openrouter", "anthropic/claude", "medium"))
            ]
        )
        let directory = try makeEditingDirectory(machine: machine, projects: [project])
        defer { cleanupEditingDirectory(directory) }

        let file = editingProjectFileURL(directory, "slashroute")
        let originalText = try String(contentsOf: file, encoding: .utf8)
        #expect(originalText.contains(#"{ cli = "openrouter", model = "anthropic/claude", effort = "medium" }"#))

        let configuration = try Configuration.load(directory: directory)
        let reloadedRoute = configuration.projects.first?.routingOverrides.first?.route
        #expect(reloadedRoute == (try editingRoute("openrouter", "anthropic/claude", "medium")))
    }

    @Test("A route with an empty part renders as an inline table and the loader refuses it")
    func routeWithEmptyPartIsRefused() throws {
        let machine = try testEditingMachine()
        let project = try testEditingProject(id: "emptyroute")
        let directory = try makeEditingDirectory(machine: machine, projects: [project])
        defer { cleanupEditingDirectory(directory) }

        let file = editingProjectFileURL(directory, "emptyroute")
        let originalText = try String(contentsOf: file, encoding: .utf8)

        var draft = ProjectFileDraft(project)
        draft.routingOverrides = [RoutingEntryDraft(route: RouteDraft(cli: "claude", model: "", effort: "medium"))]
        let newText = draft.renderedTOML
        #expect(newText.contains(#"{ cli = "claude", model = "", effort = "medium" }"#))

        let result = Result { () throws(ConfigurationEditError) in
            try Configuration.save(newText, to: file, in: directory, replacing: originalText)
        }
        guard case .failure(let error) = result, case .refused(let errors) = error else {
            Issue.record("expected .refused")
            return
        }
        #expect(errors.count == 1)
        guard case .emptyString = errors[0].reason else {
            Issue.record("expected .emptyString, got \(errors[0].reason)")
            return
        }
    }

    // MARK: - load(directory:reading:as:)

    @Test("load(directory:reading:as:) uses the substituted text, not disk")
    func loadReadingAsUsesSubstitutedText() throws {
        let machine = try testEditingMachine()
        let project = try testEditingProject(id: "substituted")
        let directory = try makeEditingDirectory(machine: machine, projects: [project])
        defer { cleanupEditingDirectory(directory) }

        let file = editingProjectFileURL(directory, "substituted")
        var draft = ProjectFileDraft(project)
        draft.name = "Substituted Name"

        let configuration = try Configuration.load(directory: directory, reading: file, as: draft.renderedTOML)
        #expect(configuration.projects.first?.name == "Substituted Name")

        // Disk itself is untouched.
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        #expect(!onDisk.contains("Substituted Name"))
    }
}
