import Domain
import Foundation

// How a reference found in a Repo is matched to one of its siblings: by path, by remote URL, or (for a registry
// range) by package name.

extension RepoDependencyScan {
    /// Another Repo of the Project, with what a reference can be matched against.
    struct Sibling: Sendable {
        let name: String
        /// Standardised absolute path.
        let path: String
        /// The normalised `origin` URL read from `.git/config`, when there is one.
        let origin: String?
        /// The `name` of the sibling's own `package.json`, when it has one.
        let packageName: String?

        init(_ repo: ScannedRepo) {
            name = repo.name
            path = RepoDependencyScan.standardised(repo.path, relativeTo: nil)
            origin = RepoDependencyScan.originURL(ofRepoAt: path).flatMap(RepoDependencyScan.normalisedURL)
            packageName = RepoDependencyScan.packageName(ofRepoAt: path)
        }
    }

    /// The consumer being scanned and the siblings its references can resolve to.
    struct Context: Sendable {
        let consumer: ScannedRepo
        /// Standardised absolute path of the consumer's root.
        let root: String
        let siblings: [Sibling]

        func sibling(path: String) -> Sibling? {
            let target = RepoDependencyScan.standardised(path, relativeTo: root)
            return siblings.first { $0.path == target }
        }

        func sibling(url: String) -> Sibling? {
            guard let target = RepoDependencyScan.normalisedURL(url) else { return nil }
            return siblings.first { $0.origin == target }
        }

        func sibling(packageName: String) -> Sibling? {
            siblings.first { $0.packageName == packageName }
        }
    }

    /// A reference to a sibling, with the guess at how it is read.
    struct Finding: Sendable {
        let producer: String
        let via: RepoDependencyVia?
        let file: String
        let reference: String
    }

    /// What one consumer's scan collects.
    struct Sink: Sendable {
        var findings: [Finding] = []
        var skipped: [SkippedFile] = []
    }

    // MARK: - Paths

    /// An absolute path, a `~` path, or one relative to `root`, with `.` and `..` resolved and no trailing slash.
    static func standardised(_ path: String, relativeTo root: String?) -> String {
        var expanded = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/"), let root {
            expanded = root + "/" + expanded
        }
        var result = URL(filePath: expanded).standardizedFileURL.path(percentEncoded: false)
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    // MARK: - URLs

    /// A remote URL in one comparable spelling (`host/org/repo`), or nil for an empty string.
    static func normalisedURL(_ raw: String) -> String? {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if url.hasPrefix("git+") { url.removeFirst(4) }
        for scheme in ["ssh://", "https://", "http://", "git://"] where url.hasPrefix(scheme) {
            url.removeFirst(scheme.count)
            break
        }
        url = withoutUserInfo(url)
        // `host:org/repo`, the scp-like spelling, but never a port.
        if let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/"),
           !startsWithPort(url[url.index(after: colon)...]) {
            url.replaceSubrange(colon...colon, with: "/")
        }
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix(".git") { url.removeLast(4) }
        while url.hasSuffix("/") { url.removeLast() }
        guard let slash = url.firstIndex(of: "/") else { return url.lowercased() }
        return url[..<slash].lowercased() + url[slash...]
    }

    private static func startsWithPort(_ rest: Substring) -> Bool {
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        return !digits.isEmpty && (digits.endIndex == rest.endIndex || rest[digits.endIndex] == "/")
    }

    private static func withoutUserInfo(_ url: String) -> String {
        guard let at = url.firstIndex(of: "@") else { return url }
        let head = url[..<at]
        return head.contains("/") ? url : String(url[url.index(after: at)...])
    }

    /// `github:org/repo` and a bare `org/repo` mean `github.com/org/repo`; nil for anything else.
    static func githubShorthandURL(_ reference: String) -> String? {
        var body = reference
        if body.hasPrefix("github:") { body.removeFirst("github:".count) } else if body.contains(":") { return nil }
        let parts = body.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) })
        else { return nil }
        return "https://github.com/" + body
    }

    // MARK: - Reading a sibling's identity

    /// The `url` of `[remote "origin"]` in the repository's config, following a `.git` file to its git directory
    /// (and, for a linked Worktree, its `commondir`).
    static func originURL(ofRepoAt path: String) -> String? {
        guard let gitDirectory = gitDirectory(ofRepoAt: path) else { return nil }
        var configDirectory = gitDirectory
        if let common = readText(gitDirectory + "/commondir")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !common.isEmpty {
            configDirectory = standardised(common, relativeTo: gitDirectory)
        }
        guard let config = readText(configDirectory + "/config") else { return nil }
        return remoteURL(named: "origin", inGitConfig: config)
    }

    private static func gitDirectory(ofRepoAt path: String) -> String? {
        let dotGit = path + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let text = readText(dotGit) else { return nil }
        let prefix = "gitdir:"
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        return standardised(String(line.dropFirst(prefix.count)), relativeTo: path)
    }

    private static func remoteURL(named remote: String, inGitConfig config: String) -> String? {
        var inRemote = false
        for rawLine in config.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = line.lowercased().filter { !$0.isWhitespace }
                inRemote = header == "[remote\"\(remote)\"]"
                continue
            }
            guard inRemote, let equals = line.firstIndex(of: "=") else { continue }
            if line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "url" {
                return line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func packageName(ofRepoAt path: String) -> String? {
        guard let text = readText(path + "/package.json"), let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["name"] as? String
    }

    // MARK: - Reading files

    static func readText(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// What reading a scanned file found.
    enum FileText {
        case missing
        case unreadable(String)
        case text(String)
    }

    /// The text of the file at `path`, or why it could not be read; a missing file is not a problem.
    static func readFile(_ path: String, maximumBytes: Int = 1_048_576) -> FileText {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return .missing }
        let size = (try? manager.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        guard size <= maximumBytes else { return .unreadable("larger than 1 MB") }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .unreadable("could not be read as UTF-8 text")
        }
        return .text(text)
    }

    /// Reads `relativeFile` under the consumer's root; a file that cannot be read is named in `sink`.
    static func scanText(of relativeFile: String, in context: Context, into sink: inout Sink) -> String? {
        switch readFile(context.root + "/" + relativeFile) {
        case .missing:
            return nil
        case .unreadable(let reason):
            sink.skipped.append(SkippedFile(file: context.consumer.name + "/" + relativeFile, reason: reason))
            return nil
        case .text(let text):
            return text
        }
    }
}
