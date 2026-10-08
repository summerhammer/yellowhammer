import Foundation

/// What GitHub said about a token when asked who it is (`GET /user`).
public enum GitHubAuthentication: Equatable, Sendable {
    /// `scopes` is the parsed `X-OAuth-Scopes` header, or nil when GitHub sent none — which is what a
    /// fine-grained token looks like.
    case authenticated(login: String, scopes: [String]?)
    /// GitHub refused the token (HTTP 401): wrong, revoked or expired.
    case rejected
    /// No verdict: GitHub could not be reached, was rate limiting, or answered something unexpected. The
    /// message never contains the token.
    case unavailable(String)
}

/// What a token can do on one repository (`GET /repos/{owner}/{repo}`), as far as GitHub lets a read-only
/// call tell.
public enum GitHubRepositoryAccess: Equatable, Sendable {
    /// A classic or OAuth token whose scopes and whose user's role allow pushing.
    case canPush
    /// The user's role allows pushing, but the token is fine-grained (no scopes header). GitHub exposes no
    /// API for a token's own grants, so its Contents and Pull requests write access cannot be confirmed
    /// without writing.
    case canPushUnverifiedToken
    /// The repository answers, but the user has no push permission on it.
    case noPushPermission
    /// A classic or OAuth token lacks the named scope (`repo`).
    case missingScope(String)
    /// The repository does not exist, or is not selected for / visible to this token.
    case notFound
    /// GitHub refused the token (HTTP 401).
    case rejected
    /// No verdict; the message never contains the token.
    case unavailable(String)
}

/// Asks GitHub whether a token is good and whether it can push to a repository. Read-only: it only issues
/// `GET`s, never writes to GitHub, and never logs or returns the token.
public struct GitHubCredentialCheck: Sendable {
    private let transport: any GitHubTransport
    private let apiVersion: String

    public init(
        transport: any GitHubTransport = URLSessionGitHubTransport(),
        apiVersion: String = "2022-11-28"
    ) {
        self.transport = transport
        self.apiVersion = apiVersion
    }

    /// `GET /user`: 200 → who the token belongs to and its scopes; 401 → rejected; anything else (a
    /// rate-limit 403, another status, a transport error) → unavailable. A nil `token` sets no
    /// `Authorization` header, for a transport that authenticates itself (``GHCLITransport``).
    public func authenticate(token: String?) async -> GitHubAuthentication {
        let outcome = await get("https://api.github.com/user", token: token)
        switch outcome {
        case .failure(let message):
            return .unavailable(message)
        case .success(let data, let response):
            switch response.statusCode {
            case 200:
                guard let user = try? JSONDecoder().decode(UserBody.self, from: data) else {
                    return .unavailable("GitHub answered with a body that could not be read")
                }
                return .authenticated(login: user.login, scopes: Self.scopes(of: response))
            case 401:
                return .rejected
            default:
                return .unavailable(Self.unavailableMessage(response))
            }
        }
    }

    /// `GET /repos/{owner}/{repo}`. `scopes` is what ``authenticate(token:)`` reported: non-nil for a
    /// classic or OAuth token (whose scopes can be checked), nil for a fine-grained token. A nil `token`
    /// sets no `Authorization` header, as in ``authenticate(token:)``.
    public func access(
        token: String?, owner: String, repository: String, scopes: [String]?
    ) async -> GitHubRepositoryAccess {
        let outcome = await get("https://api.github.com/repos/\(owner)/\(repository)", token: token)
        switch outcome {
        case .failure(let message):
            return .unavailable(message)
        case .success(let data, let response):
            switch response.statusCode {
            case 200:
                return Self.access(from: data, scopes: scopes)
            case 401:
                return .rejected
            case 404:
                return .notFound
            case 403 where !Self.isRateLimited(response):
                return .notFound
            default:
                return .unavailable(Self.unavailableMessage(response))
            }
        }
    }

    private static func access(from data: Data, scopes: [String]?) -> GitHubRepositoryAccess {
        guard let repository = try? JSONDecoder().decode(RepositoryBody.self, from: data) else {
            return .unavailable("GitHub answered with a body that could not be read")
        }
        if let scopes {
            let isPublic = repository.isPrivate == false
            let hasScope = scopes.contains("repo") || (isPublic && scopes.contains("public_repo"))
            if !hasScope { return .missingScope("repo") }
        }
        guard repository.permissions?.push == true else { return .noPushPermission }
        return scopes == nil ? .canPushUnverifiedToken : .canPush
    }

    private enum Outcome {
        case success(Data, HTTPURLResponse)
        case failure(String)
    }

    private func get(_ urlString: String, token: String?) async -> Outcome {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "GET"
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        do {
            let (data, response) = try await transport.send(request)
            return .success(data, response)
        } catch {
            return .failure("GitHub could not be reached (\(String(describing: type(of: error))))")
        }
    }

    private static func isRateLimited(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "x-ratelimit-remaining")?
            .trimmingCharacters(in: .whitespaces) == "0"
    }

    private static func unavailableMessage(_ response: HTTPURLResponse) -> String {
        if response.statusCode == 403, isRateLimited(response) {
            return "GitHub is rate limiting this token; try again later"
        }
        return "GitHub answered HTTP \(response.statusCode)"
    }

    /// The comma-separated `X-OAuth-Scopes` header, trimmed; nil when the header is absent.
    private static func scopes(of response: HTTPURLResponse) -> [String]? {
        guard let header = response.value(forHTTPHeaderField: "X-OAuth-Scopes") else { return nil }
        return header.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

private struct UserBody: Decodable {
    let login: String
}

private struct RepositoryPermissions: Decodable {
    let push: Bool?
}

private struct RepositoryBody: Decodable {
    let isPrivate: Bool?
    let permissions: RepositoryPermissions?

    enum CodingKeys: String, CodingKey {
        case isPrivate = "private"
        case permissions
    }
}
