/// Names an App Installation in records and copy: its local name (the
/// `[board.linear.installations.<name>]` key) and its Linear workspace ID. The workspace's display name
/// is not stored (spec OQ117), so copy that names the workspace uses the local name.
public struct AppInstallationLabel: Equatable, Sendable {
    /// The local name, the machine file's table key.
    public let name: String
    /// The Linear workspace this App Installation was installed into.
    public let workspace: BoardObjectID

    public init(name: String, workspace: BoardObjectID) {
        self.name = name
        self.workspace = workspace
    }
}
