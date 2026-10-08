import Foundation

/// A throwaway `~/.config/yellowhammer` in the temporary directory. Nothing is written until asked.
struct ConfigurationDirectory: ~Copyable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appending(component: "yh-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var path: String { url.path(percentEncoded: false) }

    func createDirectory() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func writeMachineFile(_ contents: String = Self.machineFile) throws {
        try createDirectory()
        try contents.write(to: url.appending(component: "config.toml"), atomically: true, encoding: .utf8)
    }

    func writeProjectFile(id: String, _ contents: String) throws {
        let projects = url.appending(component: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try contents.write(to: projects.appending(component: "\(id).toml"), atomically: true, encoding: .utf8)
    }

    /// A valid Project file declaring one working Repo at `repoPath`. With `rehearsal`, it also declares
    /// its rehearsal context (OQ149): the Linear project `<id>-rehearsal` and ``rehearsalJournal(id:)``.
    func writeValidProjectFile(id: String, repoPath: String? = nil, rehearsal: Bool = false) throws {
        let rehearsalProject = rehearsal ? ", rehearsal_project = \"\(id)-rehearsal\"" : ""
        let rehearsalTable = rehearsal
            ? "rehearsal = { journal = \"\(rehearsalJournal(id: id).path(percentEncoded: false))\" }\n" : ""
        try writeProjectFile(id: id, """
            id = "\(id)"
            name = "\(id)"
            board = { linear = { connection = "acme", project = "\(id)"\(rehearsalProject) } }
            code_hosting = { connection = "github" }
            \(rehearsalTable)spec_source = "~/Developer/\(id)-spec"

            [[repos]]
            name = "backend"
            path = "\(repoPath ?? "~/Developer/\(id)-backend")"
            role = "backend"
            check = "swift test"
            """)
    }

    /// Where ``writeValidProjectFile(id:repoPath:rehearsal:)`` declares a Project's rehearsal Journal:
    /// in this directory, outside `journals/`.
    func rehearsalJournal(id: String) -> URL {
        url.appending(components: "rehearsal", "\(id).db", directoryHint: .notDirectory)
    }

    /// A machine file holding only the `github` Keychain token connection.
    static let githubOnly = "[code_hosting.github.connections.github]\ntype = \"keychain\"\n"
        + "credential = \"keychain:github\"\n"

    static let machineFile = """
        [board.linear.connections.acme]
        credential = "keychain:linear"
        workspace = "workspace-1"
        yellowhammer_identity = "app-user-1"

        [code_hosting.github.connections.github]
        type = "keychain"
        credential = "keychain:github"
        """
}
