import Domain
import Foundation

/// The Publication Port's pull request read over GitHub's REST API (feature-authoring/select-the-next-feature,
/// `#pull-request-read`; OQ190 items 20, 27 and 28): builds the `GET` and translates GitHub's answer into
/// ``ObservedPullRequest``s or a ``PullRequestReadFailure``. No GitHub shape leaves this module. Reads only the
/// fields item 20 allows — never a title, body, review, comment, approval or check.
enum GitHubPullRequestRead {
    /// Pull requests per page when listing a head branch's: one page, which a Feature Branch never outgrows.
    static let pageSize = 100

    /// `GET /repos/{owner}/{repo}/pulls/{number}`, or `GET /repos/{owner}/{repo}/pulls?head={owner}:{branch}&state=all`.
    static func request(_ query: PullRequestQuery, token: String?, apiVersion: String) -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        switch query.selector {
        case .number(let number):
            components.path = "/repos/\(query.owner)/\(query.repository)/pulls/\(number)"
        case .headBranch(let branch):
            components.path = "/repos/\(query.owner)/\(query.repository)/pulls"
            components.percentEncodedQueryItems = [
                URLQueryItem(name: "head", value: encoded("\(query.owner):\(branch)")),
                URLQueryItem(name: "state", value: "all"),
                URLQueryItem(name: "per_page", value: String(pageSize))
            ]
        }
        return GitHubAdapter.apiRequest(url: components.url!, method: "GET", token: token, apiVersion: apiVersion)
    }

    /// 200 → the pull requests read (none is an empty answer); 401 → credential refused; 403 with the rate limit
    /// spent, or 429 → rate limited; any other 403, or 404 → no access; 5xx → unreachable; an undecodable body
    /// or any other status → an unreadable answer.
    static func map(
        data: Data, response: HTTPURLResponse, selector: PullRequestQuery.Selector
    ) throws(PullRequestReadFailure) -> [ObservedPullRequest] {
        switch response.statusCode {
        case 200:
            return try decode(data, selector: selector)
        case 401:
            throw PullRequestReadFailure(.credentialRefused, detail: "GitHub refused the request with HTTP 401")
        case 403 where isRateLimited(response), 429:
            throw PullRequestReadFailure(.rateLimited, detail: "GitHub's rate limit was reached")
        case 403, 404:
            throw PullRequestReadFailure(
                .noAccess, detail: "GitHub answered HTTP \(response.statusCode) for the pull request"
            )
        case 500...599:
            throw PullRequestReadFailure(.unreachable, detail: "GitHub answered HTTP \(response.statusCode)")
        default:
            throw PullRequestReadFailure(.unreadableAnswer, detail: "GitHub answered HTTP \(response.statusCode)")
        }
    }

    private static func decode(
        _ data: Data, selector: PullRequestQuery.Selector
    ) throws(PullRequestReadFailure) -> [ObservedPullRequest] {
        let payloads: [PullRequestPayload]
        do {
            switch selector {
            case .number:
                payloads = [try JSONDecoder().decode(PullRequestPayload.self, from: data)]
            case .headBranch:
                payloads = try JSONDecoder().decode([PullRequestPayload].self, from: data)
            }
        } catch {
            throw PullRequestReadFailure(.unreadableAnswer, detail: "GitHub's answer could not be read")
        }
        var read: [ObservedPullRequest] = []
        for payload in payloads {
            guard let observed = payload.observed else {
                throw PullRequestReadFailure(.unreadableAnswer, detail: "GitHub named an unknown pull request state")
            }
            read.append(observed)
        }
        return read
    }

    /// The rate limit is spent (`X-RateLimit-Remaining: 0`), or GitHub asked to wait (`Retry-After`, its secondary
    /// rate limit).
    private static func isRateLimited(_ response: HTTPURLResponse) -> Bool {
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining")?
            .trimmingCharacters(in: .whitespaces) == "0" {
            return true
        }
        return response.value(forHTTPHeaderField: "Retry-After") != nil
    }

    /// A query value percent-encoded so `&`, `=`, `+` and `#` in a branch name stay part of it.
    private static func encoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// The fields of one GitHub pull request the read decodes. `merged_at` is the merge test's evidence: the list
/// endpoint carries no `merged` flag, and `merge_commit_sha` names GitHub's test merge until the pull request merges.
private struct PullRequestPayload: Decodable {
    struct Head: Decodable {
        let sha: String
        let ref: String
    }

    struct Base: Decodable {
        let ref: String
    }

    let number: Int
    let htmlURL: String
    let state: String
    let mergedAt: String?
    let mergeCommitSHA: String?
    let head: Head
    let base: Base

    enum CodingKeys: String, CodingKey {
        case number
        case htmlURL = "html_url"
        case state
        case mergedAt = "merged_at"
        case mergeCommitSHA = "merge_commit_sha"
        case head
        case base
    }

    /// Nil when GitHub names a state other than `open` or `closed`.
    var observed: ObservedPullRequest? {
        let observedState: ObservedPullRequestState
        switch (state, mergedAt) {
        case (_, .some):
            observedState = .merged
        case ("open", nil):
            observedState = .open
        case ("closed", nil):
            observedState = .closedWithoutMerge
        default:
            return nil
        }
        return ObservedPullRequest(
            number: number, url: htmlURL, state: observedState, mergeCommit: mergeCommitSHA, headCommit: head.sha,
            headBranch: head.ref, baseBranch: base.ref
        )
    }
}
