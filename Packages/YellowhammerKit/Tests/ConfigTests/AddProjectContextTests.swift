import Config
import Domain
import Foundation
import Testing

@Suite("Add Project context")
struct AddProjectContextTests {
    @Test("Repo owners, Spec Source readers and the union of file ids come from the configuration")
    func fromConfiguration() throws {
        let acme = try testEditingProject(id: "acme", name: "Acme")
        let beta = try testEditingProject(id: "beta", name: "Beta Co")
        var shared = try testEditingProject(id: "gamma", name: "Gamma")
        shared.specSource = acme.specSource
        let directory = try makeEditingDirectory(
            machine: try testEditingMachine(), projects: [acme, beta, shared]
        )
        defer { cleanupEditingDirectory(directory) }
        let configuration = try Configuration.load(directory: directory)

        let context = AddProjectContext(
            configuration: configuration,
            projectFileIDs: ["refused"],
            journalProjectIDs: ["old"],
            teams: [SetupChoices.Team(id: "t", key: "ENG", name: "Engineering")]
        )

        #expect(context.existingProjectIDs == ["acme", "beta", "gamma", "refused"])
        #expect(context.journalProjectIDs == ["old"])
        #expect(context.teams.map(\.key) == ["ENG"])
        #expect(context.repoOwners[AddProjectContext.normalizedPath("~/dev/acme-backend")] == "Acme")
        #expect(context.repoOwners[AddProjectContext.normalizedPath("~/dev/beta-backend")] == "Beta Co")
        let specKey = AddProjectContext.normalizedPath("~/dev/acme-spec")
        #expect(context.specSourceReaders[specKey]?.sorted() == ["Acme", "Gamma"])
        #expect(context.specSourceReaders[AddProjectContext.normalizedPath("~/dev/beta-spec")] == ["Beta Co"])
    }

    @Test("The default context is empty")
    func empty() {
        let context = AddProjectContext()
        #expect(context.existingProjectIDs.isEmpty)
        #expect(context.repoOwners.isEmpty)
        #expect(context.specSourceReaders.isEmpty)
        #expect(context.journalProjectIDs.isEmpty)
        #expect(context.teams.isEmpty)
    }

    @Test("Paths normalize ~, trailing slashes and dot segments")
    func normalizedPath() {
        let home = NSHomeDirectory()
        let expected = URL(filePath: home).appending(path: "dev/a").path(percentEncoded: false)
        #expect(AddProjectContext.normalizedPath("~/dev/a") == expected)
        #expect(AddProjectContext.normalizedPath("\(home)/dev/a/") == expected)
        #expect(AddProjectContext.normalizedPath("\(home)/dev/b/../a") == expected)
    }
}
