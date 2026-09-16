import CryptoKit
import Domain
import Foundation

extension MainlineReader {
    /// Computes the SHA-256 of the UTF-8 bytes as lowercase hex.
    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Transcribes contracts from paths within a repository configured in `projectRepositories`.
    public func transcribe(
        paths: [String],
        repository: String,
        in projectRepositories: ProjectRepositories,
        symbol: String? = nil,
        commit: String? = nil,
        mainlines: ResolvedMainlines? = nil
    ) async throws -> TranscriptionBlock {
        guard !paths.isEmpty else {
            throw MainlineReadError.fileNotFound(path: "", commit: commit ?? "", repository: repository)
        }

        let firstRead = try await readFile(
            path: paths[0],
            repository: repository,
            in: projectRepositories,
            commit: commit,
            mainlines: mainlines
        )
        let resolvedCommit = firstRead.commit

        var contents: [String] = [firstRead.content]
        for nextPath in paths.dropFirst() {
            let fileRead = try await readFile(
                path: nextPath,
                repository: repository,
                in: projectRepositories,
                commit: resolvedCommit,
                mainlines: mainlines
            )
            contents.append(fileRead.content)
        }

        let combined = contents.joined(separator: "\n")
        let hash = Self.sha256(combined)

        return TranscriptionBlock(
            repository: repository,
            paths: paths,
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
        repository: String,
        in projectRepositories: ProjectRepositories,
        symbol: String? = nil,
        commit: String? = nil,
        mainlines: ResolvedMainlines? = nil
    ) async throws -> TranscriptionBlock {
        try await transcribe(
            paths: [path],
            repository: repository,
            in: projectRepositories,
            symbol: symbol,
            commit: commit,
            mainlines: mainlines
        )
    }
}
