import Config
import Domain
import Foundation
import Testing

private let base = """
    id = "alpha"
    name = "Alpha"
    board = { linear = { connection = "acme", project = "ALP" } }
    spec_source = "~/spec"
    """

private let repos = """

    [[repos]]
    name = "backend"
    path = "~/backend"
    role = "backend"
    check = "none"
    """

private func parse(_ extra: String, top: String = "") throws(ConfigurationError) -> ProjectConfiguration {
    try ProjectConfiguration.parse(base + "\n" + top + repos + "\n" + extra + "\n", file: "alpha.toml")
}

private func refusal(_ extra: String, top: String = "") -> ConfigurationError? {
    do {
        _ = try parse(extra, top: top)
        return nil
    } catch {
        return error
    }
}

@Test("A Project file without the new keys gets the defaults")
func templateDefaults() throws {
    let project = try parse("")
    #expect(project.changeType == .feat)
    #expect(project.pullRequestTitle == .default(.pullRequestTitle))
    #expect(project.commitMessage == .default(.commitMessage))
    #expect(project.wipCommitMessage == .default(.wipCommitMessage))
    #expect(project.unvalidatedTemplates == nil)
}

@Test("change_type and all three templates decode")
func allKeysDecode() throws {
    let project = try parse(
        """
        [github]
        pull_request_title = "[{key}] {title}"

        [git]
        commit_message = "{type}: {work_card_key} {work_card_title}"
        wip_commit_message = "wip {type} {repository}"
        """,
        top: "change_type = \"fix\"\n"
    )
    #expect(project.changeType.rawValue == "fix")
    #expect(project.pullRequestTitle.text == "[{key}] {title}")
    #expect(project.commitMessage.text == "{type}: {work_card_key} {work_card_title}")
    #expect(project.wipCommitMessage.text == "wip {type} {repository}")
}

@Test("A [github] with only pull_request_title means no credential override")
func githubTitleWithoutCredential() throws {
    let project = try parse("[github]\npull_request_title = \"{title}\"")
    #expect(project.gitHubCredential == nil)
    #expect(project.pullRequestTitle.text == "{title}")
    let both = try parse("[github]\ncredential = \"keychain:gh\"\npull_request_title = \"{title}\"")
    #expect(both.gitHubCredential == CredentialReference("keychain:gh"))
}

@Test("An unknown token, an empty template and a non-string value are refused, naming the key")
func badTemplatesRefused() {
    let unknown = refusal("[git]\ncommit_message = \"{type}: {branch}\"")
    #expect(unknown?.key == "git.commit_message")
    #expect(unknown?.line == 12)
    #expect(unknown?.reason == .unknownTemplateToken(
        name: "branch", key: "commit_message",
        accepted: ["{type}", "{title}", "{key}", "{repository}", "{scope}",
        "{work_card_key}", "{work_card_title}", "{story}"]
    ))
    #expect(unknown?.description.contains("names {branch}, which is not a commit_message token") == true)

    #expect(refusal("[github]\npull_request_title = \"{work_card_key}\"")?.key == "github.pull_request_title")
    #expect(refusal("[git]\nwip_commit_message = \"{title}\"")?.key == "git.wip_commit_message")
    #expect(refusal("[git]\nwip_commit_message = \"\"")?.reason == .emptyString)
    #expect(refusal("[git]\nwip_commit_message = \"   \"")?.reason == .emptyString)
    #expect(refusal("[git]\ncommit_message = \"{type\"")?.reason == .unterminatedTemplateBrace(key: "commit_message"))
    #expect(refusal("[git]\ncommit_message = 3")?.reason == .typeMismatch(expected: "string", found: "integer"))
    #expect(refusal("", top: "change_type = \"\"\n")?.key == "change_type")
    #expect(refusal("", top: "change_type = \"\"\n")?.reason == .emptyString)
    #expect(refusal("", top: "change_type = 3\n")?.reason == .typeMismatch(expected: "string", found: "integer"))
}

@Test("[git] takes commit_message and wip_commit_message only")
func gitTableKeys() {
    #expect(refusal("[git]\nother = \"x\"")?.reason == .unknownKey)
    #expect(refusal("[github]\nother = \"x\"")?.key == "github.other")
}

@Test("The machine file still refuses Project-file keys")
func machineFileRejectsProjectKeys() {
    let machine = ""
    let cases: [(String, String)] = [
        ("", "change_type"),
        ("[github]\ncredential = \"c\"\n\n[git]\ncommit_message = \"{type}\"", "git"),
        ("[github]\ncredential = \"c\"\npull_request_title = \"{title}\"", "github.pull_request_title")
    ]
    for (body, key) in cases {
        let text = key == "change_type"
            ? "change_type = \"feat\"\n" + machine + "[github]\ncredential = \"c\""
            : machine + body
        do {
            _ = try MachineConfiguration.parse(text, file: "config.toml")
            Issue.record("expected \(key) to be refused in config.toml")
        } catch {
            #expect(error.reason == .unknownKey)
            #expect(error.key == key)
        }
    }
}

@Test("Render then decode again yields an equal Project, keeping all four keys")
func roundTrip() throws {
    let project = try parse(
        """
        [github]
        credential = "keychain:gh"
        pull_request_title = "[{key}] {title}"

        [git]
        commit_message = "{type}: {work_card_key}"
        wip_commit_message = "wip {branch}"
        """,
        top: "change_type = \"fix\"\n"
    )
    let rendered = project.renderedTOML
    #expect(rendered.contains("change_type = \"fix\""))
    #expect(rendered.contains("pull_request_title"))
    #expect(rendered.contains("[git]"))
    let again = try ProjectConfiguration.parse(rendered, file: "alpha.toml")
    #expect(again == project)
}

@Test("A title alone renders [github] without a credential; defaults are not written")
func renderOnlyNonDefaults() throws {
    let titleOnly = try parse("[github]\npull_request_title = \"{title}\"")
    let rendered = titleOnly.renderedTOML
    #expect(rendered.contains("[github]\npull_request_title = \"{title}\""))
    #expect(!rendered.contains("credential"))
    #expect(!rendered.contains("[git]"))
    let explicitDefault = try parse("[git]\ncommit_message = \"{type}{scope}: {work_card_title}\"")
    #expect(!explicitDefault.renderedTOML.contains("[git]"))
    #expect(try parse("", top: "change_type = \"feat\"\n").renderedTOML.contains("change_type") == false)
}

@Test("A bad template refuses that Project while a sibling Project still loads")
func badTemplateIsolatesProject() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-tmpl-\(UUID().uuidString)", directoryHint: .isDirectory)
    let projects = directory.appending(component: "projects", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let machineText = "[board.linear.connections.acme]\ncredential = \"keychain:linear\"\n"
        + "workspace = \"w1\"\nyellowhammer_identity = \"u1\"\n\n[github]\ncredential = \"keychain:github\"\n"
    try machineText.write(to: directory.appending(component: "config.toml"), atomically: true, encoding: .utf8)
    func file(_ id: String, _ path: String, _ extra: String) -> String {
        "id = \"\(id)\"\nname = \"\(id)\"\nspec_source = \"~/spec\"\n\n"
            + "[board.linear]\nconnection = \"acme\"\nproject = \"\(id)\"\n\n"
            + "[[repos]]\nname = \"b\"\npath = \"\(path)\"\nrole = \"backend\"\ncheck = \"none\"\n\n\(extra)\n"
    }
    try file("good", "~/good", "").write(
        to: projects.appending(component: "good.toml"), atomically: true, encoding: .utf8
    )
    try file("bad", "~/bad", "[git]\ncommit_message = \"{branch}\"").write(
        to: projects.appending(component: "bad.toml"), atomically: true, encoding: .utf8
    )

    let configuration = try Configuration.load(directory: directory)
    #expect(configuration.projects.map(\.id.rawValue) == ["good"])
    #expect(configuration.invalidProjects.count == 1)
    #expect(configuration.invalidProjects.first?.errors.first?.key == "git.commit_message")

    let lenient = try Configuration.loadLeniently(directory: directory)
    #expect(lenient.projects.map(\.id.rawValue) == ["bad", "good"])
    #expect(lenient.invalidProjects.isEmpty)
    let bad = try #require(lenient.projects.first)
    #expect(bad.commitMessage == .default(.commitMessage))
    #expect(bad.unvalidatedTemplates?.refusals.first?.key == "git.commit_message")
}
