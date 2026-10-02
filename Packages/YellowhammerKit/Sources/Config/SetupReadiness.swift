import Domain

/// Whether each machine-wide prerequisite of Add Project is present.
public struct SetupReadiness: Equatable, Sendable {
    public enum Prerequisite: CaseIterable, Sendable {
        case linearInstallation
        case operatorIdentity
        case agentCLIRoute

        public var title: String {
            switch self {
            case .linearInstallation: "Linear installation"
            case .operatorIdentity: "Operator identity"
            case .agentCLIRoute: "An agent CLI with a route"
            }
        }
    }

    /// The prerequisites that are absent, in `allCases` order.
    public let missing: [Prerequisite]

    /// `linearInstalled` is what `yh doctor --check linear` reported. A nil `machine` is a Mac with no
    /// loadable `config.toml`: it has neither an Operator identity nor a route.
    public init(linearInstalled: Bool, machine: MachineConfiguration?) {
        let hasOperator = machine?.operatorIdentity != nil
        let hasRoute = machine?.hasRouteToDeclaredCLI ?? false
        let present: [Prerequisite: Bool] = [
            .linearInstallation: linearInstalled,
            .operatorIdentity: hasOperator,
            .agentCLIRoute: hasRoute
        ]
        missing = Prerequisite.allCases.filter { present[$0] != true }
    }

    public var blocksAddProject: Bool { !missing.isEmpty }
}
