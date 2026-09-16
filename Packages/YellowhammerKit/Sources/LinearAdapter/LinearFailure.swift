import Domain
import Foundation

/// Translates Linear's failures — HTTP statuses, OAuth refusals, GraphQL `errors[]`, transport and
/// decoding errors — into ``BoardError``. No Linear error shape leaves this module.
///
/// Every message is scrubbed of the secrets the adapter holds before it is returned, so a vendor
/// message that echoes a token cannot carry it out.
struct LinearFailure {
    /// The client secret and, once obtained, the access token.
    var secrets: [String]

    func transport(_ error: any Error) -> BoardError {
        let reason = (error as? URLError).map { "\($0.code)" } ?? String(describing: type(of: error))
        return .unreachable(scrub("Linear could not be reached (\(reason))"))
    }

    func unreadable(_ error: any Error) -> BoardError {
        let reason: String
        switch error {
        case DecodingError.keyNotFound(let key, _):
            reason = "missing \(key.stringValue)"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context):
            reason = "unexpected value at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        default:
            reason = "not valid JSON"
        }
        return .unreadableResponse(scrub("Linear's response could not be decoded: \(reason)"))
    }

    /// A refusal from the OAuth token endpoint.
    func tokenRefused(_ data: Data, _ response: HTTPURLResponse) -> BoardError {
        if response.statusCode == 429 {
            return rateLimited(response)
        }
        struct OAuthError: Decodable { let error: String? }
        let code = (try? JSONDecoder().decode(OAuthError.self, from: data))?.error.map { " (\($0))" } ?? ""
        let message = "Linear refused the client credentials with HTTP \(response.statusCode)\(code)"
        return .notAuthenticated(scrub(message))
    }

    /// A non-2xx GraphQL response. Nil when the status is a success.
    func status(_ data: Data, _ response: HTTPURLResponse) -> BoardError? {
        switch response.statusCode {
        case 200..<300:
            return nil
        case 401, 403:
            return .notAuthenticated(scrub("Linear refused the access token with HTTP \(response.statusCode)"))
        case 429:
            return rateLimited(response)
        default:
            return graphQL(data, response) ?? .refused(scrub("Linear answered with HTTP \(response.statusCode)"))
        }
    }

    /// The GraphQL `errors[]` of a response, translated; nil when there are none.
    func graphQL(_ data: Data, _ response: HTTPURLResponse) -> BoardError? {
        guard let errors = (try? JSONDecoder().decode(LinearGraphQLEnvelope<Empty>.self, from: data))?.errors,
              !errors.isEmpty else {
            return nil
        }
        return graphQL(errors, response)
    }

    /// The first GraphQL error that names a known cause wins; otherwise the first error is refused.
    func graphQL(_ errors: [LinearGraphQLError], _ response: HTTPURLResponse) -> BoardError {
        let codes = errors.compactMap { $0.extensions?.code?.uppercased() }
        if codes.contains("RATELIMITED") {
            return rateLimited(response)
        }
        if codes.contains(where: { ["AUTHENTICATION_ERROR", "UNAUTHENTICATED"].contains($0) }) {
            return .notAuthenticated(scrub("Linear refused the access token"))
        }
        if let notFound = errors.first(where: isNotFound) {
            return .scopeNotFound(scrub("Linear reports \(plain(notFound))"))
        }
        return .refused(scrub("Linear reports \(errors.first.map(plain) ?? "an unnamed error")"))
    }

    private func rateLimited(_ response: HTTPURLResponse) -> BoardError {
        .rateLimited(retryAfter: LinearBudget.retryAfter(response), budget: LinearBudget.parse(response))
    }

    private func isNotFound(_ error: LinearGraphQLError) -> Bool {
        let text = [error.message, error.extensions?.type, error.extensions?.code]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return text.contains("not found") || text.contains("forbidden")
    }

    /// The vendor message as one plain line, bounded in length.
    private func plain(_ error: LinearGraphQLError) -> String {
        let message = error.extensions?.userPresentableMessage ?? error.message ?? "an unnamed error"
        let line = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        let bounded = line.count > 200 ? String(line.prefix(200)) + "…" : line
        if let code = error.extensions?.code {
            return "\(bounded) (\(code))"
        }
        return bounded
    }

    private func scrub(_ message: String) -> String {
        secrets.filter { !$0.isEmpty }.reduce(message) { $0.replacingOccurrences(of: $1, with: "<redacted>") }
    }

    struct Empty: Decodable {}
}
