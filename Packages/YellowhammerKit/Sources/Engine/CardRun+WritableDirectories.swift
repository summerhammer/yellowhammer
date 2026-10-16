import Domain
import Foundation

extension CardRun {
    /// A linked Worktree's index and its shared object/ref store live outside its checkout. Discover
    /// both exact directories for every worker Round; a regular checkout has just one after deduplication.
    /// Other passes receive no additional write access and do not run discovery.
    func workerWritableDirectories(for pass: RunPass, path: String) async throws -> [String] {
        guard pass == .worker else { return [] }
        var directories: [String] = []
        for option in ["--git-dir", "--git-common-dir"] {
            let result = await git.run(
                ["rev-parse", "--path-format=absolute", option], workingDirectory: path, timeout: 30
            )
            try Task.checkCancellation()
            guard result.isSuccess else {
                throw CardRunError.gitDirectoryDiscoveryFailed(
                    path: path, detail: "git rev-parse \(option) failed (\(result.exitCode)): \(result.stderr)"
                )
            }
            let directory = result.stdout.trimmingCharacters(in: .newlines)
            guard directory.hasPrefix("/"), !directory.contains("\n") else {
                throw CardRunError.gitDirectoryDiscoveryFailed(
                    path: path, detail: "git rev-parse \(option) did not return an absolute directory"
                )
            }
            if !directories.contains(directory) {
                directories.append(directory)
            }
        }
        return directories
    }
}
