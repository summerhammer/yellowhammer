import Domain
import Foundation
@testable import GitHubAdapter
import Testing

@Suite("GitHubAdapter (P10.4)")
struct GitHubAdapterTests {
    @Test("Opening a pull request sends the right method, path, headers and body")
    func requestShape() async throws {
        let stub = StubTransport(response: (201, ["html_url": "https://github.com/o/r/pull/1"]))
        let adapter = GitHubAdapter(transport: stub, token: { "sekrit" })
        let draft = PullRequestDraft(
            owner: "o", repository: "r", head: "yh-proj-feat", base: "main",
            title: "Feature X (backend)", body: "the body"
        )
        _ = try await adapter.openPullRequest(draft)

        let request = try #require(await stub.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.github.com/repos/o/r/pulls")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sekrit")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")

        let bodyData = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: String])
        #expect(json["title"] == "Feature X (backend)")
        #expect(json["head"] == "yh-proj-feat")
        #expect(json["base"] == "main")
        #expect(json["body"] == "the body")
    }

    @Test("201 maps to opened with the html_url")
    func opened() async throws {
        let stub = StubTransport(response: (201, ["html_url": "https://github.com/o/r/pull/7"]))
        let adapter = GitHubAdapter(transport: stub, token: { "sekrit" })
        let receipt = try await adapter.openPullRequest(Self.draft())
        #expect(receipt == .opened(url: "https://github.com/o/r/pull/7"))
    }

    @Test("422 naming an existing pull request maps to alreadyOpen")
    func alreadyOpen() async throws {
        let stub = StubTransport(response: (422, [
            "message": "Validation Failed",
            "errors": [["message": "A pull request already exists for octocat:yh-proj-feat."]]
        ]))
        let adapter = GitHubAdapter(transport: stub, token: { "sekrit" })
        let receipt = try await adapter.openPullRequest(Self.draft())
        #expect(receipt == .alreadyOpen)
    }

    @Test("An unrelated 422 maps to validationRejected")
    func otherValidation() async throws {
        let stub = StubTransport(response: (422, ["message": "Validation Failed"]))
        let adapter = GitHubAdapter(transport: stub, token: { "sekrit" })
        do {
            _ = try await adapter.openPullRequest(Self.draft())
            Issue.record("expected a throw")
        } catch {
            guard case .validationRejected = error else {
                Issue.record("expected validationRejected, got \(error)")
                return
            }
        }
    }

    @Test("401 maps to credentialsMissingOrInsufficient")
    func unauthorized() async throws {
        let stub = StubTransport(response: (401, ["message": "Bad credentials"]))
        let adapter = GitHubAdapter(transport: stub, token: { "sekrit" })
        do {
            _ = try await adapter.openPullRequest(Self.draft())
            Issue.record("expected a throw")
        } catch {
            guard case .credentialsMissingOrInsufficient = error else {
                Issue.record("expected credentialsMissingOrInsufficient, got \(error)")
                return
            }
        }
    }

    @Test("403 with a zero rate-limit header maps to rateLimited")
    func rateLimitedForbidden() async throws {
        let stub = StubTransport(
            response: (403, ["message": "rate limited"]),
            headers: ["X-RateLimit-Remaining": "0"]
        )
        let adapter = GitHubAdapter(transport: stub, token: { "sekrit" })
        do {
            _ = try await adapter.openPullRequest(Self.draft())
            Issue.record("expected a throw")
        } catch {
            guard case .rateLimited = error else {
                Issue.record("expected rateLimited, got \(error)")
                return
            }
        }
    }

    @Test("403 with no rate-limit header maps to credentialsMissingOrInsufficient")
    func forbiddenNoRateLimit() async throws {
        let stub = StubTransport(response: (403, ["message": "Forbidden"]))
        let adapter = GitHubAdapter(transport: stub, token: { "sekrit" })
        do {
            _ = try await adapter.openPullRequest(Self.draft())
            Issue.record("expected a throw")
        } catch {
            guard case .credentialsMissingOrInsufficient = error else {
                Issue.record("expected credentialsMissingOrInsufficient, got \(error)")
                return
            }
        }
    }

    @Test("429 maps to rateLimited")
    func tooManyRequests() async throws {
        let stub = StubTransport(response: (429, ["message": "rate limited"]))
        let adapter = GitHubAdapter(transport: stub, token: { "sekrit" })
        do {
            _ = try await adapter.openPullRequest(Self.draft())
            Issue.record("expected a throw")
        } catch {
            guard case .rateLimited = error else {
                Issue.record("expected rateLimited, got \(error)")
                return
            }
        }
    }

    @Test("404 maps to repositoryNotFound")
    func notFound() async throws {
        let stub = StubTransport(response: (404, ["message": "Not Found"]))
        let adapter = GitHubAdapter(transport: stub, token: { "sekrit" })
        do {
            _ = try await adapter.openPullRequest(Self.draft())
            Issue.record("expected a throw")
        } catch {
            guard case .repositoryNotFound = error else {
                Issue.record("expected repositoryNotFound, got \(error)")
                return
            }
        }
    }

    @Test("A token that throws is reported as credentials missing, and never appears in the error")
    func tokenClosureThrows() async throws {
        struct TokenError: Error {}
        let stub = StubTransport(response: (201, ["html_url": "https://github.com/o/r/pull/1"]))
        let adapter = GitHubAdapter(transport: stub, token: { throw TokenError() })
        do {
            _ = try await adapter.openPullRequest(Self.draft())
            Issue.record("expected a throw")
        } catch {
            #expect(!String(describing: error).contains("sekrit"))
            guard case .credentialsMissingOrInsufficient = error else {
                Issue.record("expected credentialsMissingOrInsufficient, got \(error)")
                return
            }
        }
        let stubNoCall = await stub.lastRequest
        #expect(stubNoCall == nil)
    }

    @Test("The token never appears in a thrown error's description")
    func tokenNeverLeaks() async throws {
        let stub = StubTransport(response: (401, ["message": "Bad credentials"]))
        let adapter = GitHubAdapter(transport: stub, token: { "super-secret-token" })
        do {
            _ = try await adapter.openPullRequest(Self.draft())
            Issue.record("expected a throw")
        } catch {
            #expect(!String(describing: error).contains("super-secret-token"))
        }
    }

    private static func draft() -> PullRequestDraft {
        PullRequestDraft(owner: "o", repository: "r", head: "yh-proj-feat", base: "main", title: "t", body: "b")
    }
}

/// A stub `GitHubTransport` that returns one fixed response and records the last request sent.
actor StubTransport: GitHubTransport {
    private let statusCode: Int
    private let jsonBody: [String: Any]
    private let headers: [String: String]
    private(set) var lastRequest: URLRequest?

    init(response: (Int, [String: Any]), headers: [String: String] = [:]) {
        self.statusCode = response.0
        self.jsonBody = response.1
        self.headers = headers
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let data = try JSONSerialization.data(withJSONObject: jsonBody)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: headers
        )!
        return (data, response)
    }
}
