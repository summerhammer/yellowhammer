import Foundation
import Repositories
import Testing

/// Helper for creating and managing throwaway Git repositories in temporary directories.
struct GitFixture: ~Copyable {
    let url: URL
    let git: GitRunner

    init(name: String = UUID().uuidString) {
        self.url = FileManager.default.temporaryDirectory
            .appending(component: "git-\(name)", directoryHint: .isDirectory)
        self.git = GitRunner()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var path: String { url.path(percentEncoded: false) }

    @discardableResult
    func run(_ args: [String]) -> GitCommandResult {
        git.runSync(["-C", path] + args)
    }

    func initRepo(bare: Bool = false, defaultBranch: String = "main") {
        if bare {
            _ = run(["init", "--bare", "--initial-branch=\(defaultBranch)"])
        } else {
            _ = run(["init", "--initial-branch=\(defaultBranch)"])
            _ = run(["config", "user.name", "Yellowhammer Test"])
            _ = run(["config", "user.email", "test@yellowhammer.local"])
            _ = run(["config", "commit.gpgsign", "false"])
        }
    }

    @discardableResult
    func commit(
        filename: String = "file.txt",
        content: String = "content",
        message: String = "commit"
    ) throws -> String {
        let fileURL = url.appendingPathComponent(filename)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        _ = run(["add", "."])
        _ = run(["commit", "-m", message])
        return try #require(revParse("HEAD"))
    }

    func addRemote(name: String = "origin", url remoteURL: String) {
        _ = run(["remote", "add", name, remoteURL])
    }

    func setRemoteHead(remote: String = "origin", branch: String = "main") {
        _ = run(["symbolic-ref", "refs/remotes/\(remote)/HEAD", "refs/remotes/\(remote)/\(branch)"])
    }

    func revParse(_ ref: String) -> String? {
        let result = run(["rev-parse", "--verify", "--quiet", ref])
        guard result.isSuccess else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Writes a file without staging or committing it, for exercising dirty-worktree behavior.
    func writeFile(filename: String, content: String) throws {
        let fileURL = url.appendingPathComponent(filename)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Installs an executable `hooks/<name>` script in a bare repository, such as `pre-receive`,
    /// to exercise a rejected push.
    func installHook(named name: String, script: String) throws {
        let hookURL = url.appendingPathComponent("hooks").appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: hookURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
    }
}
