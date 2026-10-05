import Domain
import Testing

struct ProjectInvocationTests {
    @Test("removeArguments passes the id as the one positional and --yes")
    func removeArgumentsVector() throws {
        let id = try #require(ProjectID(rawValue: "acme-web"))

        #expect(
            ProjectInvocation.removeArguments(project: id)
                == ["project", "remove", "acme-web", "--yes"] // glossary:ignore GL001
        )
    }
}
