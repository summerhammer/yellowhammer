import Domain
import Foundation

/// Translates GitHub's HTTP responses for `POST /repos/{owner}/{repo}/pulls` into
/// ``PublicationError``/``PullRequestReceipt``. No GitHub error shape leaves this module.
enum GitHubPullRequestFailure {
    static func map(data: Data, response: HTTPURLResponse) throws(PublicationError) -> PullRequestReceipt {
        switch response.statusCode {
        case 201:
            guard
                let payload = try? JSONDecoder().decode(GitHubPullRequestPayload.self, from: data),
                let url = payload.htmlURL
            else {
                throw .other("GitHub reported success but its response could not be read")
            }
            return .opened(url: url)
        case 422:
            if alreadyExists(data) {
                return .alreadyOpen
            }
            throw .validationRejected(detail(data, response, fallback: "GitHub rejected the pull request"))
        case 401:
            throw .credentialsMissingOrInsufficient(
                detail(data, response, fallback: "GitHub refused the request with HTTP 401")
            )
        case 403:
            if isRateLimited(response) {
                throw .rateLimited(detail(data, response, fallback: "GitHub's rate limit was reached"))
            }
            throw .credentialsMissingOrInsufficient(
                detail(data, response, fallback: "GitHub refused the request with HTTP 403")
            )
        case 429:
            throw .rateLimited(detail(data, response, fallback: "GitHub's rate limit was reached"))
        case 404:
            throw .repositoryNotFound(
                detail(data, response, fallback: "GitHub reports the repository not found or not accessible")
            )
        default:
            throw .other(detail(data, response, fallback: "GitHub answered with HTTP \(response.statusCode)"))
        }
    }

    private static func alreadyExists(_ data: Data) -> Bool {
        guard let payload = try? JSONDecoder().decode(GitHubErrorPayload.self, from: data) else {
            return false
        }
        let texts = [payload.message].compactMap { $0 }
            + (payload.errors ?? []).compactMap { $0.message }
        return texts.contains { $0.localizedCaseInsensitiveContains("A pull request already exists") }
    }

    private static func isRateLimited(_ response: HTTPURLResponse) -> Bool {
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            return true
        }
        return response.value(forHTTPHeaderField: "Retry-After") != nil
    }

    private static func detail(_ data: Data, _ response: HTTPURLResponse, fallback: String) -> String {
        guard let payload = try? JSONDecoder().decode(GitHubErrorPayload.self, from: data) else {
            return "\(fallback) (HTTP \(response.statusCode))"
        }
        let message = payload.message ?? fallback
        let extra = (payload.errors ?? []).compactMap { $0.message }.joined(separator: "; ")
        return extra.isEmpty ? message : "\(message): \(extra)"
    }
}

struct GitHubPullRequestPayload: Decodable {
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case htmlURL = "html_url"
    }
}

struct GitHubErrorPayload: Decodable {
    let message: String?
    let errors: [GitHubErrorDetail]?
}

struct GitHubErrorDetail: Decodable {
    let message: String?
}
