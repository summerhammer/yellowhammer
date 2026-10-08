import Foundation
@testable import GitHubAdapter
import Testing

@Suite("GitHubCredentialCheck")
struct GitHubCredentialCheckTests {
    private static let token = "ghp_sekrit"

    // MARK: authenticate

    @Test("authenticate GETs /user with the Bearer token and GitHub's headers")
    func authenticateRequestShape() async throws {
        let stub = RoutedStubTransport(.reply(200, headers: ["X-OAuth-Scopes": "repo"], body: #"{"login":"octocat"}"#))
        _ = await GitHubCredentialCheck(transport: stub).authenticate(token: Self.token)

        let request = try #require(await stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.github.com/user")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.httpBody == nil)
    }

    @Test("200 with scopes gives the login and the trimmed scopes")
    func authenticatedWithScopes() async {
        let stub = RoutedStubTransport(.reply(
            200, headers: ["X-OAuth-Scopes": "repo, read:org ,gist"], body: #"{"login":"octocat"}"#
        ))
        let result = await GitHubCredentialCheck(transport: stub).authenticate(token: Self.token)
        #expect(result == .authenticated(login: "octocat", scopes: ["repo", "read:org", "gist"]))
    }

    @Test("200 without a scopes header (a fine-grained token) gives nil scopes")
    func authenticatedFineGrained() async {
        let stub = RoutedStubTransport(.reply(200, body: #"{"login":"octocat"}"#))
        let result = await GitHubCredentialCheck(transport: stub).authenticate(token: Self.token)
        #expect(result == .authenticated(login: "octocat", scopes: nil))
    }

    @Test("401 is rejected")
    func authenticateRejected() async {
        let stub = RoutedStubTransport(.reply(401, body: #"{"message":"Bad credentials"}"#))
        let result = await GitHubCredentialCheck(transport: stub).authenticate(token: Self.token)
        #expect(result == .rejected)
    }

    @Test("A rate-limited 403 is unavailable, and the message never carries the token")
    func authenticateRateLimited() async throws {
        let stub = RoutedStubTransport(.reply(403, headers: ["x-ratelimit-remaining": "0"], body: "{}"))
        let result = await GitHubCredentialCheck(transport: stub).authenticate(token: Self.token)
        guard case .unavailable(let message) = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        #expect(message.contains("rate limiting"))
        #expect(!message.contains(Self.token))
    }

    @Test("Any other status is unavailable")
    func authenticateServerError() async {
        let stub = RoutedStubTransport(.reply(500, body: "{}"))
        let result = await GitHubCredentialCheck(transport: stub).authenticate(token: Self.token)
        #expect(result == .unavailable("GitHub answered HTTP 500"))
    }

    @Test("A transport error is unavailable, and the message never carries the token")
    func authenticateTransportError() async {
        let stub = RoutedStubTransport(.fail)
        let result = await GitHubCredentialCheck(transport: stub).authenticate(token: Self.token)
        guard case .unavailable(let message) = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        #expect(!message.contains(Self.token))
    }

    @Test("A 200 whose body is not a user is unavailable")
    func authenticateGarbledBody() async {
        let stub = RoutedStubTransport(.reply(200, body: "not json"))
        let result = await GitHubCredentialCheck(transport: stub).authenticate(token: Self.token)
        #expect(result == .unavailable("GitHub answered with a body that could not be read"))
    }

    // MARK: access

    @Test("access GETs /repos/{owner}/{repo} with the Bearer token and GitHub's headers")
    func accessRequestShape() async throws {
        let stub = RoutedStubTransport(.reply(200, body: Self.repo(isPrivate: true, push: true)))
        _ = await Self.access(stub, scopes: ["repo"])

        let request = try #require(await stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.github.com/repos/acme/backend")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test("A classic token with the repo scope and push permission can push")
    func canPush() async {
        let stub = RoutedStubTransport(.reply(200, body: Self.repo(isPrivate: true, push: true)))
        #expect(await Self.access(stub, scopes: ["repo", "read:org"]) == .canPush)
    }

    @Test("A fine-grained token with push permission can push, unverified")
    func canPushUnverified() async {
        let stub = RoutedStubTransport(.reply(200, body: Self.repo(isPrivate: true, push: true)))
        #expect(await Self.access(stub, scopes: nil) == .canPushUnverifiedToken)
    }

    @Test("A classic token without the repo scope is missing it on a private repository")
    func missingRepoScope() async {
        let stub = RoutedStubTransport(.reply(200, body: Self.repo(isPrivate: true, push: true)))
        #expect(await Self.access(stub, scopes: ["gist", "public_repo"]) == .missingScope("repo"))
    }

    @Test("public_repo is enough on a public repository")
    func publicRepoScope() async {
        let stub = RoutedStubTransport(.reply(200, body: Self.repo(isPrivate: false, push: true)))
        #expect(await Self.access(stub, scopes: ["public_repo"]) == .canPush)
    }

    @Test("A classic token with no scopes at all is missing the repo scope")
    func emptyScopes() async {
        let stub = RoutedStubTransport(.reply(200, body: Self.repo(isPrivate: false, push: true)))
        #expect(await Self.access(stub, scopes: []) == .missingScope("repo"))
    }

    @Test("push: false is no push permission")
    func noPush() async {
        let stub = RoutedStubTransport(.reply(200, body: Self.repo(isPrivate: true, push: false)))
        #expect(await Self.access(stub, scopes: ["repo"]) == .noPushPermission)
        #expect(await Self.access(stub, scopes: nil) == .noPushPermission)
    }

    @Test("404 is notFound")
    func repositoryNotFound() async {
        let stub = RoutedStubTransport(.reply(404, body: #"{"message":"Not Found"}"#))
        #expect(await Self.access(stub, scopes: ["repo"]) == .notFound)
    }

    @Test("A 403 that is not rate limiting is notFound")
    func forbiddenIsNotFound() async {
        let stub = RoutedStubTransport(.reply(403, body: #"{"message":"Resource not accessible"}"#))
        #expect(await Self.access(stub, scopes: nil) == .notFound)
    }

    @Test("A rate-limited 403 is unavailable")
    func accessRateLimited() async {
        let stub = RoutedStubTransport(.reply(403, headers: ["X-RateLimit-Remaining": "0"], body: "{}"))
        let result = await Self.access(stub, scopes: nil)
        guard case .unavailable(let message) = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        #expect(!message.contains(Self.token))
    }

    @Test("401 is rejected")
    func accessRejected() async {
        let stub = RoutedStubTransport(.reply(401, body: #"{"message":"Bad credentials"}"#))
        #expect(await Self.access(stub, scopes: ["repo"]) == .rejected)
    }

    @Test("A transport error is unavailable")
    func accessTransportError() async {
        let stub = RoutedStubTransport(.fail)
        let result = await Self.access(stub, scopes: ["repo"])
        guard case .unavailable(let message) = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        #expect(!message.contains(Self.token))
    }

    @Test("A 200 whose body is not a repository is unavailable")
    func accessGarbledBody() async {
        let stub = RoutedStubTransport(.reply(200, body: "<html>"))
        #expect(await Self.access(stub, scopes: ["repo"])
            == .unavailable("GitHub answered with a body that could not be read"))
    }

    // MARK: Helpers

    private static func access(_ stub: RoutedStubTransport, scopes: [String]?) async -> GitHubRepositoryAccess {
        await GitHubCredentialCheck(transport: stub).access(
            token: token, owner: "acme", repository: "backend", scopes: scopes
        )
    }

    private static func repo(isPrivate: Bool, push: Bool) -> String {
        #"{"private":\#(isPrivate),"permissions":{"push":\#(push)}}"#
    }
}

/// A `GitHubTransport` that answers every request the same way and records them.
actor RoutedStubTransport: GitHubTransport {
    enum Answer: Sendable {
        case reply(Int, headers: [String: String] = [:], body: String)
        case fail
    }

    private let answer: Answer
    private(set) var requests: [URLRequest] = []

    init(_ answer: Answer) {
        self.answer = answer
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        switch answer {
        case .fail:
            throw URLError(.notConnectedToInternet)
        case .reply(let status, let headers, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            return (Data(body.utf8), response)
        }
    }
}
