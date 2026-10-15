import Config
import Domain
import Foundation
import Testing

/// A Project file with the given `[[repos]]` blocks; the header is eleven lines, so the first block
/// starts on line 12.
private func projectText(id: String = "deps", repos: [String]) -> String {
    """
    id = "\(id)"
    name = "Deps"
    spec_source = "~/dev/\(id)-spec"

    [board.linear]
    connection = "acme"
    project = "DEP"

    [code_hosting]
    connection = "github"

    \(repos.joined(separator: "\n"))
    """
}

private func repoBlock(_ name: String, consumes: String? = nil, extra: String? = nil) -> String {
    var lines = [
        "[[repos]]", "name = \"\(name)\"", "path = \"~/dev/deps/\(name)\"", "role = \"backend\"",
        "check = \"swift test\""
    ]
    if let consumes { lines.append("consumes = \(consumes)") }
    if let extra { lines.append(extra) }
    return lines.joined(separator: "\n") + "\n"
}

private func edge(_ repo: String, _ via: String) -> String {
    "{ repo = \"\(repo)\", via = \"\(via)\" }"
}

private func refusal(_ text: String) -> ConfigurationError? {
    do {
        _ = try ProjectConfiguration.parse(text, file: "deps.toml")
        return nil
    } catch {
        return error
    }
}

private func lineOf(_ text: String, _ needle: String) -> Int {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    return (lines.firstIndex { $0.contains(needle) } ?? -2) + 1
}

@Test("Two declared edges decode onto the consumer, in order, and reach the Domain Repo")
func edgesDecodeOntoTheConsumer() throws {
    let text = projectText(repos: [
        repoBlock("backend", consumes: "[\(edge("contracts", "tag")), \(edge("shared", "mainline"))]"),
        repoBlock("contracts"),
        repoBlock("shared")
    ])
    let configuration = try ProjectConfiguration.parse(text, file: "deps.toml")
    let expected = [
        RepoDependency(producer: "contracts", via: .tag),
        RepoDependency(producer: "shared", via: .mainline)
    ]
    #expect(configuration.repos[0].consumes == expected)
    #expect(configuration.repos[1].consumes.isEmpty)
    #expect(configuration.projectRepositories.workingRepos[0].consumes == expected)
    #expect(configuration.projectRepositories.workingRepos[2].consumes.isEmpty)
}

@Test("A multi-line array of inline tables decodes, and an empty array declares no edges")
func multiLineAndEmptyArraysDecode() throws {
    let multiLine = """
        consumes = [
          \(edge("contracts", "tag")),
          \(edge("shared", "mainline")),
        ]
        """
    let text = projectText(repos: [
        repoBlock("backend") + multiLine + "\n",
        repoBlock("contracts", consumes: "[]"),
        repoBlock("shared")
    ])
    let configuration = try ProjectConfiguration.parse(text, file: "deps.toml")
    #expect(configuration.repos[0].consumes.count == 2)
    #expect(configuration.repos[1].consumes.isEmpty)
}

@Test("Omitting consumes declares no edges")
func omittedConsumesIsEmpty() throws {
    let configuration = try ProjectConfiguration.parse(
        projectText(repos: [repoBlock("backend")]), file: "deps.toml"
    )
    #expect(configuration.repos[0].consumes.isEmpty)
    #expect(configuration.projectRepositories.workingRepos[0].consumes.isEmpty)
}

@Test("A forward reference to a Repo declared later is not a dangling producer")
func forwardReferenceResolves() throws {
    let text = projectText(repos: [
        repoBlock("backend", consumes: "[\(edge("contracts", "tag"))]"),
        repoBlock("contracts")
    ])
    #expect(refusal(text) == nil)
}

@Test("An edge naming no Repo of the Project is refused, the Spec Source included")
func unknownProducerIsRefused() {
    for name in ["ghost", "spec_source"] {
        let text = projectText(repos: [repoBlock("backend", consumes: "[\(edge(name, "tag"))]")])
        let error = refusal(text)
        #expect(error?.reason == .unknownRepoDependencyProducer(name))
        #expect(error?.key == "repos[0].consumes[0].repo")
        #expect(error?.line == lineOf(text, "consumes ="))
    }
}

@Test("A Repo consuming itself is refused")
func selfEdgeIsRefused() {
    let text = projectText(repos: [repoBlock("backend", consumes: "[\(edge("backend", "tag"))]")])
    let error = refusal(text)
    #expect(error?.reason == .selfRepoDependency)
    #expect(error?.key == "repos[0].consumes[0].repo")
}

@Test("A repeated producer for one consumer is refused on the second edge")
func repeatedProducerIsRefused() {
    let text = projectText(repos: [
        repoBlock("backend", consumes: "[\(edge("contracts", "tag")), \(edge("contracts", "mainline"))]"),
        repoBlock("contracts")
    ])
    let error = refusal(text)
    let line = lineOf(text, "consumes =")
    #expect(error?.reason == .duplicateRepoDependency(producer: "contracts", firstLine: line))
    #expect(error?.key == "repos[0].consumes[1].repo")
}

@Test("A cycle is refused and named as a path starting at its first Repo in file order")
func cycleIsRefusedWithItsPath() {
    let text = projectText(repos: [
        repoBlock("a", consumes: "[\(edge("b", "tag"))]"),
        repoBlock("b", consumes: "[\(edge("c", "mainline"))]"),
        repoBlock("c", consumes: "[\(edge("a", "tag"))]")
    ])
    let error = refusal(text)
    #expect(error?.reason == .repoDependencyCycle(path: ["a", "b", "c", "a"]))
    #expect(error?.key == "repos[0].consumes[0].repo")
    #expect(error?.description.contains("a -> b -> c -> a") == true)
}

@Test("A cycle that does not include the first Repo is named from its own first Repo")
func cycleBehindAnAcyclicPrefixIsNamedFromItsOwnStart() {
    let text = projectText(repos: [
        repoBlock("entry", consumes: "[\(edge("z", "tag"))]"),
        repoBlock("x", consumes: "[\(edge("y", "tag"))]"),
        repoBlock("y", consumes: "[\(edge("z", "tag"))]"),
        repoBlock("z", consumes: "[\(edge("x", "tag"))]")
    ])
    #expect(refusal(text)?.reason == .repoDependencyCycle(path: ["x", "y", "z", "x"]))
}

@Test("A diamond is not a cycle")
func diamondIsNotACycle() {
    let text = projectText(repos: [
        repoBlock("app", consumes: "[\(edge("left", "tag")), \(edge("right", "tag"))]"),
        repoBlock("left", consumes: "[\(edge("base", "tag"))]"),
        repoBlock("right", consumes: "[\(edge("base", "mainline"))]"),
        repoBlock("base")
    ])
    #expect(refusal(text) == nil)
}

@Test("A missing via is refused as a missing key; there is no default")
func missingViaIsRefused() {
    let text = projectText(repos: [
        repoBlock("backend", consumes: "[{ repo = \"contracts\" }]"),
        repoBlock("contracts")
    ])
    let error = refusal(text)
    #expect(error?.reason == .missingKey)
    #expect(error?.key == "repos[0].consumes[0].via")
}

@Test("An unknown via is refused")
func unknownViaIsRefused() {
    let text = projectText(repos: [
        repoBlock("backend", consumes: "[\(edge("contracts", "branch"))]"),
        repoBlock("contracts")
    ])
    let error = refusal(text)
    #expect(error?.reason == .invalidRepoDependencyVia("branch"))
    #expect(error?.key == "repos[0].consumes[0].via")
}

@Test("An unknown key inside an edge is refused like any unknown key")
func unknownKeyInEdgeIsRefused() {
    let text = projectText(repos: [
        repoBlock("backend", consumes: "[{ repo = \"contracts\", via = \"tag\", pin = \"v1\" }]"),
        repoBlock("contracts")
    ])
    let error = refusal(text)
    #expect(error?.reason == .unknownKey)
    #expect(error?.key == "repos[0].consumes[0].pin")
}

@Test("An empty producer name and a non-table element are refused")
func malformedEdgeShapesAreRefused() {
    let empty = projectText(repos: [repoBlock("backend", consumes: "[\(edge("", "tag"))]")])
    #expect(refusal(empty)?.reason == .emptyString)
    #expect(refusal(empty)?.key == "repos[0].consumes[0].repo")

    let notTable = projectText(repos: [repoBlock("backend", consumes: "[\"contracts\"]")])
    #expect(refusal(notTable)?.reason == .typeMismatch(expected: "table", found: "string"))
    #expect(refusal(notTable)?.key == "repos[0].consumes[0]")
}

@Test("A cyclic Project is refused alone; its valid sibling in the same directory still loads")
func cyclicProjectIsIsolatedFromItsSibling() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "repo-dependency-\(UUID().uuidString)", directoryHint: .isDirectory)
    let projects = directory.appending(path: "projects", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let machine = """
        [board.linear.connections]
        acme = { credential = "keychain:linear", workspace = "workspace-1", yellowhammer_identity = "app-user-1" }
        [code_hosting.github.connections.github]
        type = "keychain"
        credential = "keychain:github"

        [cli.claude]

        [[routing]]
        route = "claude/sonnet"
        """
    try machine.write(to: directory.appending(path: "config.toml"), atomically: true, encoding: .utf8)

    let cyclic = projectText(id: "cyclic", repos: [
        repoBlock("cyclic-a", consumes: "[\(edge("cyclic-b", "tag"))]"),
        repoBlock("cyclic-b", consumes: "[\(edge("cyclic-a", "tag"))]")
    ])
    let valid = projectText(id: "valid", repos: [
        repoBlock("valid-a", consumes: "[\(edge("valid-b", "tag"))]"),
        repoBlock("valid-b")
    ])
    let cyclicURL = projects.appending(path: "cyclic.toml")
    try cyclic.write(to: cyclicURL, atomically: true, encoding: .utf8)
    try valid.write(to: projects.appending(path: "valid.toml"), atomically: true, encoding: .utf8)

    let configuration = try Configuration.load(directory: directory)
    #expect(configuration.projects.map(\.id.rawValue) == ["valid"])
    #expect(configuration.projects.first?.repos.first?.consumes == [RepoDependency(producer: "valid-b", via: .tag)])
    let invalid = try #require(configuration.invalidProjects.first)
    #expect(configuration.invalidProjects.count == 1)
    #expect(invalid.errors.map(\.reason) == [.repoDependencyCycle(path: ["cyclic-a", "cyclic-b", "cyclic-a"])])
}

@Test("A Repo's consumes edges round-trip through the draft and renderedTOML")
func edgesRoundTripThroughRendering() throws {
    let text = projectText(repos: [
        repoBlock("backend", consumes: "[\(edge("contracts", "tag")), \(edge("shared", "mainline"))]"),
        repoBlock("contracts"),
        repoBlock("shared")
    ])
    let configuration = try ProjectConfiguration.parse(text, file: "deps.toml")
    let draft = ProjectFileDraft(configuration)
    #expect(draft.repos[0].consumes == configuration.repos[0].consumes)

    let rendered = draft.renderedTOML
    #expect(rendered.contains("consumes = [{ repo = \"contracts\", via = \"tag\" }"))
    #expect(rendered.components(separatedBy: "consumes =").count == 2)
    let parsed = try ProjectConfiguration.parse(rendered, file: "roundtrip.toml")
    #expect(parsed.repos.map(\.consumes) == configuration.repos.map(\.consumes))
}

@Test("A RepoDraft built with consumes renders them; one without writes no consumes key")
func repoDraftRendersConsumesOnlyWhenNonEmpty() throws {
    let configuration = try ProjectConfiguration.parse(
        projectText(repos: [repoBlock("backend"), repoBlock("contracts")]), file: "deps.toml"
    )
    var draft = ProjectFileDraft(configuration)
    #expect(!draft.renderedTOML.contains("consumes"))

    draft.repos[0] = RepoDraft(
        name: "backend", path: "~/dev/deps/backend", role: "backend", check: "swift test",
        consumes: [RepoDependency(producer: "contracts", via: .mainline)]
    )
    let parsed = try ProjectConfiguration.parse(draft.renderedTOML, file: "draft.toml")
    #expect(parsed.repos[0].consumes == [RepoDependency(producer: "contracts", via: .mainline)])
    #expect(parsed.repos[1].consumes.isEmpty)
}
