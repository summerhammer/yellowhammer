import Domain
import Foundation
@testable import GitHubAdapter
import Testing

// feature-authoring/select-the-next-feature #pull-request-read (OQ190 items 20, 27, 28 and 29): the Publication
// Port's second operation reads a pull request by number, or every pull request whose head is a branch, in any
// state, over the same transports and credential as the pull request it opened. Each refusal maps to one of
// the five reasons; finding no pull request is an empty answer.

private func pullRequestJSON(
    number: Int = 7, state: String = "closed", mergedAt: String? = "2026-10-26T17:45:00Z",
    mergeCommit: String? = "abe5f4b8", head: String = "dc9ff665", headRef: String = "yh-proj-feat",
    base: String = "main"
) -> String {
    let mergedAtJSON = mergedAt.map { "\"\($0)\"" } ?? "null"
    let mergeCommitJSON = mergeCommit.map { "\"\($0)\"" } ?? "null"
    return """
        {"number":\(number),"html_url":"https://github.com/o/r/pull/\(number)","state":"\(state)",\
        "merged_at":\(mergedAtJSON),"merge_commit_sha":\(mergeCommitJSON),\
        "head":{"sha":"\(head)","ref":"\(headRef)"},"base":{"ref":"\(base)"},\
        "title":"never read","body":"never read"}
        """
}

private func adapter(_ transport: any GitHubTransport, token: String? = "sekrit") -> GitHubAdapter {
    GitHubAdapter(transport: transport, token: { token })
}

private let byNumber = PullRequestQuery(owner: "o", repository: "r", selector: .number(7))
private let byHead = PullRequestQuery(owner: "o", repository: "r", selector: .headBranch("yh-proj/feat"))

/// The reason a read threw, or nil when it did not throw.
private func failureReason(
    _ transport: any GitHubTransport, query: PullRequestQuery = byNumber
) async -> PullRequestReadFailure.Reason? {
    do {
        _ = try await adapter(transport).readPullRequests(query)
        return nil
    } catch {
        return error.reason
    }
}

@Suite("GitHubAdapter: the pull request read (OQ190)")
struct GitHubAdapterPullRequestReadTests {
    @Test("A read by number is GET /repos/{owner}/{repo}/pulls/{number} with the credential and API headers")
    func byNumberRequestShape() async throws {
        let stub = RoutedStubTransport(.reply(200, body: pullRequestJSON()))
        _ = try await adapter(stub).readPullRequests(byNumber)

        let request = try #require(await stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.github.com/repos/o/r/pulls/7")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sekrit")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.httpBody == nil)
    }

    @Test("A merged pull request decodes its state, merge commit, head commit and branch, and base branch")
    func decodesAMergedPullRequest() async throws {
        let stub = RoutedStubTransport(.reply(200, body: pullRequestJSON()))
        let read = try await adapter(stub).readPullRequests(byNumber)

        #expect(read == [
            ObservedPullRequest(
                number: 7, url: "https://github.com/o/r/pull/7", state: .merged, mergeCommit: "abe5f4b8",
                headCommit: "dc9ff665", headBranch: "yh-proj-feat", baseBranch: "main"
            )
        ])
    }

    @Test("An open pull request reads open, and GitHub's test-merge commit is not a merge commit")
    func decodesAnOpenPullRequest() async throws {
        let stub = RoutedStubTransport(.reply(200, body: pullRequestJSON(state: "open", mergedAt: nil)))
        let read = try await adapter(stub).readPullRequests(byNumber)

        #expect(read.map(\.state) == [.open])
        #expect(read.first?.mergeCommit == nil)
    }

    @Test("A closed pull request with no merge time reads closed without merge")
    func decodesAClosedPullRequest() async throws {
        let stub = RoutedStubTransport(.reply(200, body: pullRequestJSON(state: "closed", mergedAt: nil)))
        let read = try await adapter(stub).readPullRequests(byNumber)

        #expect(read.map(\.state) == [.closedWithoutMerge])
        #expect(read.first?.mergeCommit == nil)
    }

    @Test("A read by head branch lists the branch's pull requests in any state, the head qualified by owner")
    func byHeadRequestShape() async throws {
        let stub = RoutedStubTransport(.reply(200, body: "[]"))
        _ = try await adapter(stub).readPullRequests(byHead)

        let request = try #require(await stub.requests.first)
        #expect(request.httpMethod == "GET")
        let url = try #require(request.url)
        #expect(url.host == "api.github.com")
        #expect(url.path == "/repos/o/r/pulls")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "head" }?.value == "o:yh-proj/feat")
        #expect(items.first { $0.name == "state" }?.value == "all")
        #expect(items.first { $0.name == "per_page" }?.value == "100")
    }

    @Test("A read by head branch decodes every pull request it finds")
    func decodesAList() async throws {
        let body = "[" + pullRequestJSON(number: 3, state: "closed", mergedAt: nil) + ","
            + pullRequestJSON(number: 9) + "]"
        let stub = RoutedStubTransport(.reply(200, body: body))
        let read = try await adapter(stub).readPullRequests(byHead)

        #expect(read.map(\.number) == [3, 9])
        #expect(read.map(\.state) == [.closedWithoutMerge, .merged])
    }

    @Test("Finding no pull request for the head branch is an empty answer, not a failure")
    func noPullRequestIsEmpty() async throws {
        let stub = RoutedStubTransport(.reply(200, body: "[]"))
        #expect(try await adapter(stub).readPullRequests(byHead).isEmpty)
    }

    @Test("A transport that cannot reach GitHub reads as unreachable")
    func unreachable() async {
        #expect(await failureReason(RoutedStubTransport(.fail)) == .unreachable)
    }

    @Test("A 5xx reads as unreachable")
    func serverError() async {
        #expect(await failureReason(RoutedStubTransport(.reply(502, body: "{}"))) == .unreachable)
    }

    @Test("401 reads as credential refused")
    func unauthorized() async {
        let stub = RoutedStubTransport(.reply(401, body: #"{"message":"Bad credentials"}"#))
        #expect(await failureReason(stub) == .credentialRefused)
    }

    @Test("A token that cannot be resolved reads as credential refused, and nothing is sent")
    func unresolvableToken() async {
        let stub = RoutedStubTransport(.reply(200, body: "[]"))
        struct Refused: Error {}
        let adapter = GitHubAdapter(transport: stub, token: { throw Refused() })
        do {
            _ = try await adapter.readPullRequests(byHead)
            Issue.record("expected a throw")
        } catch {
            #expect(error.reason == .credentialRefused)
        }
        #expect(await stub.requests.isEmpty)
    }

    @Test("403 with the rate limit spent, or 429, reads as rate limited")
    func rateLimited() async {
        let spent = RoutedStubTransport(.reply(403, headers: ["X-RateLimit-Remaining": "0"], body: "{}"))
        #expect(await failureReason(spent) == .rateLimited)
        let retryAfter = RoutedStubTransport(.reply(403, headers: ["Retry-After": "60"], body: "{}"))
        #expect(await failureReason(retryAfter) == .rateLimited)
        #expect(await failureReason(RoutedStubTransport(.reply(429, body: "{}"))) == .rateLimited)
    }

    @Test("Any other 403, and 404, read as no access")
    func noAccess() async {
        #expect(await failureReason(RoutedStubTransport(.reply(403, body: "{}"))) == .noAccess)
        #expect(await failureReason(RoutedStubTransport(.reply(404, body: "{}"))) == .noAccess)
        #expect(await failureReason(RoutedStubTransport(.reply(404, body: "{}")), query: byHead) == .noAccess)
    }

    @Test("A 200 whose body cannot be read reads as an unreadable answer")
    func unreadable() async {
        #expect(await failureReason(RoutedStubTransport(.reply(200, body: "not json"))) == .unreadableAnswer)
        #expect(await failureReason(RoutedStubTransport(.reply(200, body: "{}"))) == .unreadableAnswer)
        #expect(
            await failureReason(RoutedStubTransport(.reply(200, body: "{}")), query: byHead) == .unreadableAnswer
        )
    }

    @Test("Over the gh transport the read stays on api.github.com and is a plain GET")
    func overGH() async throws {
        let gh = try StubGH(stdout: "HTTP/2.0 200 OK\nContent-Type: application/json\n\n[" + pullRequestJSON() + "]")
        defer { gh.remove() }
        let adapter = GitHubAdapter(transport: GHCLITransport(executable: gh.executable), token: { nil })

        let read = try await adapter.readPullRequests(byHead)

        #expect(read.map(\.number) == [7])
        let arguments = try gh.arguments()
        #expect(arguments.starts(with: ["api", "-i", "-X", "GET"]))
        let path = try #require(arguments.last)
        #expect(path.hasPrefix("/repos/o/r/pulls?"))
        #expect(path.contains("head=o:yh-proj/feat"))
        #expect(path.contains("state=all"))
        #expect(!arguments.contains("--input"))
        #expect(!arguments.contains { $0.lowercased().contains("authorization") })
    }

    @Test("gh reporting it is not authenticated reads as credential refused")
    func ghLoggedOut() async throws {
        let gh = try StubGH(stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exitCode: 4)
        defer { gh.remove() }
        let adapter = GitHubAdapter(transport: GHCLITransport(executable: gh.executable), token: { nil })
        do {
            _ = try await adapter.readPullRequests(byNumber)
            Issue.record("expected a throw")
        } catch {
            #expect(error.reason == .credentialRefused)
        }
    }
}
