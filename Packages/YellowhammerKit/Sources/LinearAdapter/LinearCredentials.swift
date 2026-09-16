/// The registered Linear OAuth application's client credentials.
///
/// Its descriptions redact the secret, so interpolating the value into a log line cannot leak it.
public struct LinearCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let clientID: String
    let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public var description: String {
        "LinearCredentials(clientID: \(clientID), clientSecret: <redacted>)"
    }

    public var debugDescription: String { description }
}
