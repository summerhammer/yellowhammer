import Domain

/// Whether each machine-wide prerequisite of Add Project is present. Linear and the Operator identity
/// are not among them: the wizard's Linear step chooses the Linear workspace and its Operator identity.
public struct SetupReadiness: Equatable, Sendable {
    public enum Prerequisite: CaseIterable, Sendable {
        case agentCLIRoute

        public var title: String {
            switch self {
            case .agentCLIRoute: "An agent CLI with a route"
            }
        }
    }

    /// The prerequisites that are absent, in `allCases` order.
    public let missing: [Prerequisite]

    /// A nil `machine` is a Mac with no loadable `config.toml`: it has no route.
    public init(machine: MachineConfiguration?) {
        let hasRoute = machine?.hasRouteToDeclaredCLI ?? false
        let present: [Prerequisite: Bool] = [.agentCLIRoute: hasRoute]
        missing = Prerequisite.allCases.filter { present[$0] != true }
    }

    public var blocksAddProject: Bool { !missing.isEmpty }
}
