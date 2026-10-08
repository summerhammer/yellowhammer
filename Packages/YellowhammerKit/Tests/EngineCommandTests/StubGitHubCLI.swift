import Foundation
import Repositories
@testable import EngineCommand

/// A `#!/bin/sh` stand-in for `gh` in a fresh temp directory. It answers `gh api -i … /user` with a canned
/// HTTP 200 for the login in its `login` file and `/repos/…` with push permission per its `push` file, so a
/// test can rewrite either between two calls. `mode` switches it to a logged-out gh (exit 4, empty stdout) or
/// to one that fails with stderr only. Every invocation's arguments are appended to the `calls` file.
/// `EngineCommandTests` may not import the adapter (MB2), so ``GitHubCredentialValidation`` reaches it through
/// its own `gh` transport.
final class StubGitHubCLI: Sendable {
    enum Mode: String {
        case loggedIn = "ok"
        case loggedOut = "loggedout"
        case failing = "fail"
    }

    let directory: URL
    var path: String { directory.appendingPathComponent("gh").path }

    init(login: String = "octocat", mode: Mode = .loggedIn, canPush: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-gh-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        dir='\(directory.path)'
        echo "$*" >> "$dir/calls"
        case "$(cat "$dir/mode")" in
        loggedout)
            echo "To get started with GitHub CLI, please run:  gh auth login" 1>&2
            exit 4
            ;;
        fail)
            echo "gh: connection refused" 1>&2
            exit 2
            ;;
        esac
        for last; do :; done
        case "$last" in
        /user)
            printf 'HTTP/2.0 200 OK\\nX-Oauth-Scopes: repo\\n\\n{"login":"%s"}' "$(cat "$dir/login")"
            ;;
        /repos/*)
            printf 'HTTP/2.0 200 OK\\n\\n{"private":true,"permissions":{"push":%s}}' "$(cat "$dir/push")"
            ;;
        *)
            printf 'HTTP/2.0 404 Not Found\\n\\n{}'
            exit 1
            ;;
        esac
        """
        let executable = directory.appendingPathComponent("gh")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try set(login: login)
        try set(mode: mode)
        try set(canPush: canPush)
    }

    func set(login: String) throws {
        try Data(login.utf8).write(to: directory.appendingPathComponent("login"))
    }

    func set(mode: Mode) throws {
        try Data(mode.rawValue.utf8).write(to: directory.appendingPathComponent("mode"))
    }

    func set(canPush: Bool) throws {
        try Data((canPush ? "true" : "false").utf8).write(to: directory.appendingPathComponent("push"))
    }

    /// One line per invocation: the arguments gh was called with. Empty when it was never run.
    var calls: [String] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A validation whose `gh` is this stub; a Repo's slug is `acme/<last path component>` and the token path
    /// reaches nothing.
    func validation(found: Bool = true) -> GitHubCredentialValidation {
        let executable = found ? path : nil
        return GitHubCredentialValidation(
            send: { _ in throw URLError(.notConnectedToInternet) },
            resolveSlug: { path in
                GitHubRepositorySlug(owner: "acme", repository: (path as NSString).lastPathComponent)
            },
            resolveGitHubCLI: { _ in executable }
        )
    }
}
