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

    /// A valid Project file declaring one working Repo at `repoPath`.
    func writeValidProjectFile(id: String, repoPath: String? = nil) throws {
        try writeProjectFile(id: id, """
            id = "\(id)"
            name = "\(id)"
            board = { linear = { installation = "acme", project = "\(id)" } }
            spec_source = "~/Developer/\(id)-spec"

            [[repos]]
            name = "backend"
            path = "\(repoPath ?? "~/Developer/\(id)-backend")"
            role = "backend"
            check = "swift test"
            """)
    }

    static let machineFile = """
        [board.linear.installations.acme]
        credential = "keychain:linear"
        workspace = "workspace-1"
        app_user = "app-user-1"

        [github]
        credential = "keychain:github"
        """
}
