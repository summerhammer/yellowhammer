import Domain
import Foundation

/// The GitHub implementation of the Publication Port (roadmap P10.4): `POST
/// /repos/{owner}/{repo}/pulls`, nothing else. It authenticates with a token resolved lazily, per
/// call, through an injected closure — never eagerly, and never logged or placed in an error. A nil token
/// sets no `Authorization` header: the transport authenticates (``GHCLITransport`` does, as `gh`'s active
/// account). It translates GitHub's response and never decides: no retry.
public struct GitHubAdapter: Publication, Sendable {
    private let transport: any GitHubTransport
    /// Resolves the bearer token for one call, or nil when the transport authenticates. Called once per
    /// `openPullRequest`, never cached here.
    private let token: @Sendable () throws -> String?
    private let apiVersion: String

    public init(
        transport: any GitHubTransport = URLSessionGitHubTransport(),
        apiVersion: String = "2022-11-28",
        token: @escaping @Sendable () throws -> String?
    ) {
        self.transport = transport
        self.apiVersion = apiVersion
        self.token = token
    }

    public func openPullRequest(_ draft: PullRequestDraft) async throws(PublicationError) -> PullRequestReceipt {
        let resolvedToken: String?
        do {
            resolvedToken = try token()
        } catch {
            throw .credentialsMissingOrInsufficient(
                "the GitHub token could not be resolved for \(draft.owner)/\(draft.repository)"
            )
        }

        let request = Self.makeRequest(draft, token: resolvedToken, apiVersion: apiVersion)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw .transport("GitHub could not be reached (\(String(describing: type(of: error))))")
        }

        return try GitHubPullRequestFailure.map(data: data, response: response)
    }

    private static func makeRequest(_ draft: PullRequestDraft, token: String?, apiVersion: String) -> URLRequest {
        let url = URL(
            string: "https://api.github.com/repos/\(draft.owner)/\(draft.repository)/pulls"
        )!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = GitHubCreatePullRequestBody(
            title: draft.title, head: draft.head, base: draft.base, body: draft.body
        )
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }
}

struct GitHubCreatePullRequestBody: Encodable {
    let title: String
    let head: String
    let base: String
    let body: String
}
