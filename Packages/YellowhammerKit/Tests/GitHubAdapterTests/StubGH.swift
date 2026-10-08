import Foundation

/// A `#!/bin/sh` stand-in for `gh` in a fresh temp directory: it records its argv, stdin and a few
/// environment variables to files, prints canned stdout and stderr, and exits with a chosen code.
struct StubGH {
    let directory: URL
    var executable: String { directory.appendingPathComponent("gh").path }

    init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-gh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(stdout.utf8).write(to: directory.appendingPathComponent("canned-stdout"))
        try Data(stderr.utf8).write(to: directory.appendingPathComponent("canned-stderr"))
        let script = """
        #!/bin/sh
        dir='\(directory.path)'
        printf '%s\\n' "$@" > "$dir/argv"
        cat > "$dir/stdin"
        printf '%s|%s|%s|%s' "$GH_PROMPT_DISABLED" "$GH_NO_UPDATE_NOTIFIER" \
            "$GH_NO_EXTENSION_UPDATE_NOTIFIER" "$NO_COLOR" > "$dir/env"
        cat "$dir/canned-stdout"
        cat "$dir/canned-stderr" 1>&2
        exit \(exitCode)
        """
        let path = directory.appendingPathComponent("gh")
        try Data(script.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The arguments gh was called with, one per line.
    func arguments() throws -> [String] {
        let text = try String(contentsOf: directory.appendingPathComponent("argv"), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func stdin() throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("stdin"))
    }

    /// `GH_PROMPT_DISABLED|GH_NO_UPDATE_NOTIFIER|GH_NO_EXTENSION_UPDATE_NOTIFIER|NO_COLOR` as gh saw them.
    func environment() throws -> String {
        try String(contentsOf: directory.appendingPathComponent("env"), encoding: .utf8)
    }
}
