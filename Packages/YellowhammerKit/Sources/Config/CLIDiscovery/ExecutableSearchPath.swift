import Foundation

/// The ordered, de-duplicated directories an agent CLI is looked up in, each tagged with where it came from.
/// Built from plain values so it is the same list wherever it is built; it never reads `PATH` itself.
public struct ExecutableSearchPath: Equatable, Sendable {
    /// Where a directory on the search path came from.
    public enum Source: Equatable, Sendable {
        /// The Operator's login-shell `PATH`.
        case loginShell
        /// The `PATH` of the process doing the search.
        case appProcess
        /// `/etc/paths` and `/etc/paths.d/*`.
        case systemPaths
        /// A directory a package manager or installer is known to use.
        case knownLocation
    }

    public struct Entry: Equatable, Sendable {
        public let directory: String
        public let source: Source

        public init(directory: String, source: Source) {
            self.directory = directory
            self.source = source
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// The search path for the given inputs, in order: the login-shell `PATH`, the process `PATH`, the system
    /// paths, then the known `locations`. `PATH` strings are split on `:`; empty and relative segments and the
    /// transient `fnm_multishells` directories are dropped, a leading `~/` is expanded against
    /// `homeDirectory`, each directory is normalised lexically (symlinks are not resolved), and only the first
    /// occurrence of a directory is kept.
    public static func composed(
        loginShellPATH: String?,
        processPATH: String?,
        systemPaths: [String],
        locations: [CLISearchLocation],
        homeDirectory: String
    ) -> ExecutableSearchPath {
        let login = directories(inPATH: loginShellPATH, homeDirectory: homeDirectory)
        let process = directories(inPATH: processPATH, homeDirectory: homeDirectory)
        let system = systemPaths.compactMap { clean($0, homeDirectory: homeDirectory) }
        var entries: [Entry] = []
        entries += login.map { Entry(directory: $0, source: .loginShell) }
        entries += process.map { Entry(directory: $0, source: .appProcess) }
        entries += system.map { Entry(directory: $0, source: .systemPaths) }
        return ExecutableSearchPath(entries: entries).appending(locations: locations, homeDirectory: homeDirectory)
    }

    /// A copy with the directories of `locations` added after the existing ones, as ``Source/knownLocation``.
    /// A directory already on the path keeps its earlier entry.
    public func appending(locations: [CLISearchLocation], homeDirectory: String) -> ExecutableSearchPath {
        let added = locations.flatMap { $0.directories(homeDirectory: homeDirectory) }
            .compactMap { Self.clean($0, homeDirectory: homeDirectory) }
            .map { Entry(directory: $0, source: .knownLocation) }
        var seen = Set<String>()
        let kept = (entries + added).filter { seen.insert($0.directory).inserted }
        return ExecutableSearchPath(entries: kept)
    }

    /// The directories in `/etc/paths`, then those in each file of `/etc/paths.d` by file name: lines trimmed,
    /// blank lines skipped. A missing file or directory contributes nothing.
    public static func systemPaths(etcDirectory: String = "/etc") -> [String] {
        var files = ["\(etcDirectory)/paths"]
        let dropIns = ((try? FileManager.default.contentsOfDirectory(atPath: "\(etcDirectory)/paths.d")) ?? []).sorted()
        files += dropIns.map { "\(etcDirectory)/paths.d/\($0)" }
        return files.flatMap { file -> [String] in
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    /// `path` with `//`, a trailing `/`, `.` and `..` folded away lexically. Symlinks are not resolved.
    public static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func directories(inPATH path: String?, homeDirectory: String) -> [String] {
        guard let path else { return [] }
        return path.split(separator: ":", omittingEmptySubsequences: true)
            .compactMap { clean(String($0), homeDirectory: homeDirectory) }
    }

    private static func clean(_ segment: String, homeDirectory: String) -> String? {
        var path = segment.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("~/") { path = homeDirectory + "/" + path.dropFirst(2) }
        guard path.hasPrefix("/"), !path.contains("/fnm_multishells/") else { return nil }
        return normalized(path)
    }
}
