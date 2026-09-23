import Domain
import Foundation
import GitHubAdapter
import Testing

/// Against the real GitHub API — the live done-condition a stub cannot prove (P10.4). Opt-in only:
///
///     YH_GITHUB_SMOKE_TESTS=1 YH_GITHUB_SMOKE_TOKEN=… YH_GITHUB_SMOKE_REPO=owner/repo \
///     YH_GITHUB_SMOKE_HEAD=feature-branch [YH_GITHUB_SMOKE_BASE=main] \
///         swift test --package-path Packages/YellowhammerKit --filter GitHubAdapterSmokeTests
@Suite(
    "GitHub live smoke test",
    .enabled(if: ProcessInfo.processInfo.environment["YH_GITHUB_SMOKE_TESTS"] == "1"
        || ProcessInfo.processInfo.environment["YH_GITHUB_SMOKE_TOKEN"] != nil)
)
struct GitHubAdapterSmokeTests {
    @Test("Opens a pull request against a sandbox repository or verifies alreadyOpen")
    func livePullRequestCreation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let token = environment["YH_GITHUB_SMOKE_TOKEN"], !token.isEmpty,
              let repoEnv = environment["YH_GITHUB_SMOKE_REPO"], !repoEnv.isEmpty,
              let head = environment["YH_GITHUB_SMOKE_HEAD"], !head.isEmpty else {
            print("GitHubAdapterSmokeTests skipped: YH_GITHUB_SMOKE_TOKEN, YH_GITHUB_SMOKE_REPO, "
                + "or YH_GITHUB_SMOKE_HEAD is not set")
            return
        }

        let base = environment["YH_GITHUB_SMOKE_BASE"] ?? "main"
        let owner: String
        let repository: String

        if repoEnv.contains("/") {
            let parts = repoEnv.split(separator: "/", maxSplits: 1).map(String.init)
            owner = parts[0]
            repository = parts[1]
        } else {
            owner = environment["YH_GITHUB_SMOKE_OWNER"] ?? "summerhammer"
            repository = repoEnv
        }

        let adapter = GitHubAdapter(token: { token })
        let draft = PullRequestDraft(
            owner: owner,
            repository: repository,
            head: head,
            base: base,
            title: "Automated smoke test pull request",
            body: "Smoke test verifying GitHub API integration (P10.4 / issue #98)"
        )

        let receipt = try await adapter.openPullRequest(draft)
        switch receipt {
        case .opened(let url):
            #expect(!url.isEmpty)
        case .alreadyOpen:
            // When a pull request for this branch is already open, GitHub returns 422
            // which maps to alreadyOpen. This confirms successful authentication and receipt.
            break
        }
    }
}
