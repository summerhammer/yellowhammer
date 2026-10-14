import CryptoKit
import Domain
import Foundation

extension MainlineReader {
    /// Computes the SHA-256 of the UTF-8 bytes as lowercase hex.
    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The lines of `content`, kept verbatim (a trailing `\r` stays). Split on `\n`; a final newline ends
    /// the last line rather than starting another, so `""` has 0 lines, `"\n"` has 1, and both `"a\nb\n"`
    /// and `"a\nb"` have 2.
    static func lines(of content: String) -> [String] {
        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Transcribes contracts from paths within a repository configured in `projectRepositories`.
    ///
    /// A path with `ranges` contributes only those lines — unioned, in file order, joined by `\n` — after
    /// every raw range is checked against the file at the resolved commit; a path without contributes its
    /// whole content. The path is read, so its errors come first, before any range is looked at.
    public func transcribe(
        paths: [String],
        ranges: [String: [LineRange]] = [:],
        repository: String,
        in projectRepositories: ProjectRepositories,
        symbol: String? = nil,
        commit: String? = nil,
        mainlines: ResolvedMainlines? = nil
    ) async throws -> TranscriptionBlock {
        guard !paths.isEmpty else {
            throw MainlineReadError.fileNotFound(path: "", commit: commit ?? "", repository: repository)
        }

        var resolvedCommit = commit
        var contents: [String] = []
        var transcribed: [String: [LineRange]] = [:]
        for path in paths {
            let fileRead = try await readFile(
                path: path,
                repository: repository,
                in: projectRepositories,
                commit: resolvedCommit,
                mainlines: mainlines
            )
            resolvedCommit = fileRead.commit
            guard let pathRanges = ranges[path], !pathRanges.isEmpty else {
                contents.append(fileRead.content)
                continue
            }
            let fileLines = Self.lines(of: fileRead.content)
            try TranscriptionRangeError.validate(
                pathRanges, repository: repository, path: path, lineCount: fileLines.count,
                commit: fileRead.commit
            )
            let unioned = LineRange.union(pathRanges)
            transcribed[path] = unioned
            contents.append(
                unioned.flatMap { fileLines[($0.start - 1)..<$0.end] }.joined(separator: "\n")
            )
        }

        let combined = contents.joined(separator: "\n")
        let hash = Self.sha256(combined)

        return TranscriptionBlock(
            repository: repository,
            paths: paths,
            ranges: transcribed,
            symbol: symbol,
            mainlineCommit: resolvedCommit,
            content: combined,
            contentHash: hash,
            authorSupplied: false,
            authorSuppliedNight: nil
        )
    }

    /// Transcribes a single path within a repository configured in `projectRepositories`.
    public func transcribe(
        path: String,
        ranges: [LineRange] = [],
        repository: String,
        in projectRepositories: ProjectRepositories,
        symbol: String? = nil,
        commit: String? = nil,
        mainlines: ResolvedMainlines? = nil
    ) async throws -> TranscriptionBlock {
        try await transcribe(
            paths: [path],
            ranges: ranges.isEmpty ? [:] : [path: ranges],
            repository: repository,
            in: projectRepositories,
            symbol: symbol,
            commit: commit,
            mainlines: mainlines
        )
    }
}
