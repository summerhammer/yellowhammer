import Domain
import Foundation

/// Translates Linear's failures — HTTP statuses, OAuth refusals, GraphQL `errors[]`, transport and
/// decoding errors — into ``BoardError``. No Linear error shape leaves this module.
///
/// Every message is scrubbed of the secrets the adapter holds before it is returned, so a vendor
/// message that echoes a token cannot carry it out.
struct LinearFailure {
    /// The Installation's access and refresh tokens, once obtained.
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

    /// A refusal exchanging or refreshing the Installation's own OAuth tokens (P17.3, ADR-005): a
    /// revoked or invalid refresh token (`invalid_request`/`invalid_grant`, L5 probe) or an outright
    /// HTTP 401 are both reported this way — the Operator's fix is the same either way, re-running the
    /// Linear step of `yh setup`.
    func installationTokenRefused(_ data: Data, _ response: HTTPURLResponse) -> BoardError {
        if response.statusCode == 429 {
            return rateLimited(response)
        }
        if (500..<600).contains(response.statusCode) {
            return .unreachable(scrub("Linear answered with HTTP \(response.statusCode)"))
        }
        let code = (try? JSONDecoder().decode(OAuthError.self, from: data))?.error.map { " (\($0))" } ?? ""
        let message = "Linear refused Yellowhammer's sign-in with HTTP \(response.statusCode)\(code)"
        return .notAuthenticated(scrub(message))
    }

    /// A non-2xx GraphQL response. Nil when the status is a success.
    func status(_ data: Data, _ response: HTTPURLResponse) -> BoardError? {
        switch response.statusCode {
        case 200..<300:
            return nil
        case 401:
            return .notAuthenticated(scrub("Linear refused the access token with HTTP \(response.statusCode)"))
        case 403:
            return .forbidden(scrub("Linear refused permission with HTTP \(response.statusCode)"))
        case 429:
            return rateLimited(response)
        case 500..<600:
            return .unreachable(scrub("Linear answered with HTTP \(response.statusCode)"))
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
        // "not found" is checked first: Linear answers some missing-entity reads with code `FORBIDDEN`
        // too (its own read-permission model conflates "does not exist" with "you may not see it"), so
        // an explicit "not found" message always wins that ambiguity. Only once the message names no
        // missing entity does a `FORBIDDEN` code or "not allowed" wording read as a permission refusal
        // (the story's own live example: "You are not allowed to create workflow states for this
        // team", code `FORBIDDEN`) — Board Provisioning Ruling, OQ80.
        if let notFound = errors.first(where: isNotFound) {
            return .scopeNotFound(scrub("Linear reports \(plain(notFound))"))
        }
        if let forbidden = errors.first(where: isForbidden) {
            return .forbidden(scrub("Linear reports \(plain(forbidden))"))
        }
        return .refused(scrub("Linear reports \(errors.first.map(plain) ?? "an unnamed error")"))
    }

    private func rateLimited(_ response: HTTPURLResponse) -> BoardError {
        .rateLimited(retryAfter: LinearBudget.retryAfter(response), budget: LinearBudget.parse(response))
    }

    private func isForbidden(_ error: LinearGraphQLError) -> Bool {
        if error.extensions?.code?.uppercased() == "FORBIDDEN" { return true }
        let text = [error.message, error.extensions?.type]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return text.contains("not allowed") || text.contains("forbidden")
    }

    private func isNotFound(_ error: LinearGraphQLError) -> Bool {
        let text = [error.message, error.extensions?.type]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return text.contains("not found")
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

    func insertConflict(_ data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(LinearGraphQLEnvelope<Empty>.self, from: data),
              let errors = envelope.errors, !errors.isEmpty else {
            return false
        }
        return errors.contains { error in
            let text = [error.message, error.extensions?.userPresentableMessage]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            return text.contains("conflict on insert")
        }
    }

    private func scrub(_ message: String) -> String {
        secrets.filter { !$0.isEmpty }.reduce(message) { $0.replacingOccurrences(of: $1, with: "<redacted>") }
    }

    private struct OAuthError: Decodable {
        let error: String?
    }

    struct Empty: Decodable {}
}
