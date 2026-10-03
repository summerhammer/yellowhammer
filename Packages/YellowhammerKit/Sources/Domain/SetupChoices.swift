/// What `yh setup --print-choices` offers the Operator to choose from, printed as one JSON line so the
/// app can drive the choices `yh setup` cannot make on the Operator's behalf: the Operator identity and,
/// per Project, the Linear team. The app has no Board Port of its own (ADR-001) — this is how it learns
/// what the workspace holds without one.
public struct SetupChoices: Codable, Equatable, Sendable {
    /// A workspace member, already filtered to Operator candidates and sorted (`OperatorIdentity.candidates(from:)`).
    public struct Member: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var displayName: String

        public init(id: String, name: String, displayName: String) {
            self.id = id
            self.name = name
            self.displayName = displayName
        }
    }

    /// A Linear team, as the board returns it.
    public struct Team: Codable, Equatable, Sendable {
        public var id: String
        public var key: String
        public var name: String

        public init(id: String, key: String, name: String) {
            self.id = id
            self.key = key
            self.name = name
        }
    }

    /// An active Linear project the Operator may adopt for a Project, as the board lists it.
    public struct LinearProject: Codable, Equatable, Sendable { // glossary:ignore GL001
        public var id: String
        public var name: String
        public var teamNames: [String]

        public init(id: String, name: String, teamNames: [String]) {
            self.id = id
            self.name = name
            self.teamNames = teamNames
        }
    }

    /// A Linear App Installation in the machine file's registry, in `config.toml` order.
    public struct Installation: Codable, Equatable, Sendable {
        public var name: String
        /// The Linear workspace ID.
        public var workspace: String
        public var operatorIdentity: String?

        public init(name: String, workspace: String, operatorIdentity: String?) {
            self.name = name
            self.workspace = workspace
            self.operatorIdentity = operatorIdentity
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: InstallationCodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            workspace = try container.decode(String.self, forKey: .workspace)
            operatorIdentity = try container.decodeIfPresent(String.self, forKey: .operatorIdentity)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: InstallationCodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(workspace, forKey: .workspace)
            try container.encodeIfPresent(operatorIdentity, forKey: .operatorIdentity)
        }
    }

    public var operatorCandidates: [Member]
    /// The selected installation's configured `operator`, only when it is still an Operator candidate;
    /// nil otherwise, including when nothing is configured or no installation was selected.
    public var configuredOperator: String?
    /// In the order the board returned them.
    public var teams: [Team]
    /// Active (neither completed nor cancelled) Linear projects, in the board's order. Absent from
    /// older `yh` output, so decoding treats a missing key as empty.
    public var linearProjects: [LinearProject] // glossary:ignore GL001
    public var cliAdapters: [String]
    /// Every registry entry, in `config.toml` order. Absent from older `yh` output, so decoding treats
    /// a missing key as empty.
    public var installations: [Installation]

    public init(
        operatorCandidates: [Member], configuredOperator: String?, teams: [Team],
        linearProjects: [LinearProject] = [], cliAdapters: [String],
        installations: [Installation] = []
    ) {
        self.installations = installations
        self.linearProjects = linearProjects
        self.operatorCandidates = operatorCandidates
        self.configuredOperator = configuredOperator
        self.teams = teams
        self.cliAdapters = cliAdapters
    }

    private enum CodingKeys: String, CodingKey {
        case operatorCandidates, configuredOperator, teams, linearProjects, cliAdapters, installations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operatorCandidates = try container.decode([Member].self, forKey: .operatorCandidates)
        configuredOperator = try container.decodeIfPresent(String.self, forKey: .configuredOperator)
        teams = try container.decode([Team].self, forKey: .teams)
        linearProjects = try container.decodeIfPresent([LinearProject].self, forKey: .linearProjects) ?? []
        cliAdapters = try container.decode([String].self, forKey: .cliAdapters)
        installations = try container.decodeIfPresent([Installation].self, forKey: .installations) ?? []
    }
}

/// `SetupChoices.Installation`'s JSON keys; the Operator identity is `operator` on the wire.
private enum InstallationCodingKeys: String, CodingKey {
    case name, workspace
    case operatorIdentity = "operator"
}
