import Domain
@testable import Engine
import Foundation
import Repositories

// The remote tip check (OQ191 item 4) reads the remote Feature Branch before every pull request open. A seam test
// whose `origin` is a GitHub URL it cannot reach hands the seam one of these instead.

extension RemoteFeatureBranchRead {
    /// Every remote Feature Branch is at `commit`: the Pushed Tip the test opens with, so the pull request opens.
    static func at(_ commit: String) -> RemoteFeatureBranchRead {
        RemoteFeatureBranchRead { _, _ in .at(commit: commit) }
    }

    /// The real `git ls-remote` read, with the GitHub URL `githubURL` rewritten to the local bare repository at
    /// `remotePath`: for a test whose `origin` fetch URL is on GitHub and whose pushes go to a local remote.
    static func rewriting(_ githubURL: String, to remotePath: String) -> RemoteFeatureBranchRead {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = "url.\(remotePath).insteadOf"
        environment["GIT_CONFIG_VALUE_0"] = githubURL
        return .git(reader: RemoteFeatureBranchReader(git: GitRunner(environment: environment)), credential: { nil })
    }
}
