/// A GitHub access token used to authenticate a push, redacted from both descriptions so that
/// interpolating the value into a log line cannot leak it.
public struct GitHubToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var description: String { "GitHubToken(<redacted>)" }

    public var debugDescription: String { description }
}
