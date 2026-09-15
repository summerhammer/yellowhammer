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
}

extension Route: CustomStringConvertible {
    public var description: String {
        "\(cli)/\(model)/\(effort)"
    }
}
