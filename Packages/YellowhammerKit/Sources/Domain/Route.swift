/// The triple `(cli, model, effort)` a Card is dispatched on.
public struct Route: Hashable, Sendable {
    public let cli: String
    public let model: String
    public let effort: String

    /// Fails when any part is empty.
    public init?(cli: String, model: String, effort: String) {
        guard !cli.isEmpty, !model.isEmpty, !effort.isEmpty else { return nil }
        self.cli = cli
        self.model = model
        self.effort = effort
    }

    /// A Route from its three-part shorthand `cli/model/effort` (Route String Ruling, OQ67): exactly
    /// three non-empty parts split on `/`, with no whitespace anywhere and nothing trimmed. Fails on
    /// anything else, the two-part `cli/model` included: an Override label inherits no effort (OQ126).
    public init?(label: String) {
        guard !label.contains(where: \.isWhitespace) else { return nil }
        let parts = label.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        self.init(cli: parts[0], model: parts[1], effort: parts[2])
    }
}

extension Route: CustomStringConvertible {
    public var description: String {
        "\(cli)/\(model)/\(effort)"
    }
}
