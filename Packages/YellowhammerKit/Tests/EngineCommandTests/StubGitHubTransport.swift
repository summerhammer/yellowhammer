import Foundation
import Repositories
import Synchronization
@testable import EngineCommand

/// Plays GitHub's side of the credential check: answers each request by its URL path, and records every
/// request. `EngineCommandTests` may not import the adapter (MB2), so ``GitHubCredentialValidation`` takes
/// this as a plain closure (`send`) and the real `GitHubCredentialCheck` runs against it.
final class StubGitHubTransport: Sendable {
    struct Reply: Sendable {
        let status: Int
        let headers: [String: String]
        let body: String

        init(_ status: Int, headers: [String: String] = [:], body: String = "{}") {
            self.status = status
            self.headers = headers
            self.body = body
        }

        /// `GET /user` for `login`; `scopes` nil sends no `X-OAuth-Scopes` header (a fine-grained token).
        static func user(_ login: String = "octocat", scopes: String? = "repo") -> Reply {
            Reply(200, headers: scopes.map { ["X-OAuth-Scopes": $0] } ?? [:], body: #"{"login":"\#(login)"}"#)
        }

        /// `GET /repos/{owner}/{repo}`.
        static func repo(isPrivate: Bool = true, push: Bool = true) -> Reply {
            Reply(200, body: #"{"private":\#(isPrivate),"permissions":{"push":\#(push)}}"#)
        }

        static let unauthorized = Reply(401, body: #"{"message":"Bad credentials"}"#)
        static let notFound = Reply(404, body: #"{"message":"Not Found"}"#)
    }

    private let routes: [String: Reply]
    private let fallback: Reply
    private let log = Mutex<[URLRequest]>([])

    /// `routes` maps a URL path (`/user`, `/repos/acme/backend`) to its reply; any other path gets `fallback`.
    init(routes: [String: Reply] = [:], fallback: Reply = .notFound) {
        self.routes = routes
        self.fallback = fallback
    }

    /// A token that GitHub accepts for `login` with the `repo` scope, and every repository it is asked
    /// about pushable. Pass `routes` to override single paths.
    static func passing(routes: [String: Reply] = [:]) -> StubGitHubTransport {
        StubGitHubTransport(routes: ["/user": .user()].merging(routes) { $1 }, fallback: .repo())
    }

    var requests: [URLRequest] { log.withLock { $0 } }

    /// The paths asked, in order.
    var paths: [String] { requests.compactMap { $0.url?.path(percentEncoded: false) } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        log.withLock { $0.append(request) }
        let path = request.url?.path(percentEncoded: false) ?? ""
        let reply = routes[path] ?? fallback
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers
        )!
        return (Data(reply.body.utf8), response)
    }

    /// A validation that talks to this stub. A Repo's slug is `acme/<last path component>`; the paths in
    /// `notGitHub` have no GitHub `origin`.
    func validation(notGitHub: Set<String> = []) -> GitHubCredentialValidation {
        GitHubCredentialValidation(
            send: { try await self.send($0) },
            resolveSlug: { path in
                guard !notGitHub.contains(path) else { return nil }
                return GitHubRepositorySlug(
                    owner: "acme", repository: (path as NSString).lastPathComponent
                )
            }
        )
    }
}
