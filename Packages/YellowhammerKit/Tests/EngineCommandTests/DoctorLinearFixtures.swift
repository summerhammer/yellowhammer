import Domain
import Engine
@testable import EngineCommand

/// Two Board Connections, `acme` (Projects alpha, gamma) and `globex` (Project beta), with a credential per
/// installation and one fake board each, for the per-installation Check 4 tests.
struct DoctorLinearFixture: ~Copyable {
    let directory = ConfigurationDirectory()
    let acme: FakeProvisioningBoard
    let globex: FakeProvisioningBoard
    let binds = DoctorBindLog()

    /// `operators` maps installation name to its configured Operator identity, if any. With
    /// `provisionAcme` false, `acme`'s board is left as found, for the test to seed and provision.
    init(
        operators: [String: String] = ["acme": "user-op", "globex": "user-op"], extraMachine: String = "",
        projects: [(id: String, installation: String)] = [("alpha", "acme"), ("gamma", "acme"), ("beta", "globex")],
        provisionAcme: Bool = true
    ) async throws {
        func entry(_ name: String, workspace: String) -> String {
            let operatorLine = operators[name].map { "operator = \"\($0)\"\n" } ?? ""
            return """
                [board.linear.connections.\(name)]
                credential = "keychain:linear-\(name)"
                workspace = "\(workspace)"
                yellowhammer_identity = "app-user-\(name)"
                \(operatorLine)
                """
        }
        try directory.writeMachineFile(
            entry("acme", workspace: "ws-acme") + "\n" + entry("globex", workspace: "ws-globex") + "\n"
                + extraMachine + "\n" + ConfigurationDirectory.githubOnly
        )
        for project in projects {
            try directory.writeProjectFile(id: project.id, """
                id = "\(project.id)"
                name = "\(project.id)"
                board = { linear = { connection = "\(project.installation)", project = "lp-\(project.id)" } }
                code_hosting = { connection = "github" }
                spec_source = "~/Developer/\(project.id)-spec"

                [[repos]]
                name = "backend"
                path = "~/Developer/\(project.id)-backend"
                role = "backend"
                check = "swift test"
                """)
        }
        acme = await Self.board(workspaceName: "Acme Inc", project: "lp-alpha", provisioned: provisionAcme)
        globex = await Self.board(workspaceName: "Globex Corp", project: "lp-beta")
    }

    static func board(workspaceName: String, project: String, provisioned: Bool = true) async -> FakeProvisioningBoard {
        let scope = BoardProjectScope(id: BoardObjectID(rawValue: project), name: project, teams: [engineeringTeam])
        let board = await makeBoard(project: scope, members: [operatorMember])
        await board.setWorkspace(BoardWorkspace(id: "ws", name: workspaceName, urlKey: "ws"))
        // Healthy means provisioned: setup has run (with a Routing Table, so the `Override` group exists
        // too), so Check 4's provisioning verification passes.
        if provisioned {
            _ = try? await BoardProvisioner.provision(
                using: board, projectName: project, createIn: nil, routingTable: RoutingTable(entries: [])
            )
        }
        return board
    }

    static let credentials = RecordingCredentialStore(seed: [
        "keychain:linear-acme": "secret", "keychain:linear-globex": "secret"
    ])

    func doctor(
        credentials: RecordingCredentialStore = DoctorLinearFixture.credentials,
        output: RecordingOutput = RecordingOutput(), checks: [DoctorCheck] = [.configuration, .linear],
        projectFilter: ProjectID? = nil
    ) -> Doctor {
        makeDoctor(
            directory: directory, boards: ["acme": acme, "globex": globex], binds: binds, credentials: credentials,
            output: output, checks: checks, projectFilter: projectFilter
        )
    }
}

extension [DoctorFinding] {
    /// Check 4's findings for one installation, by its local name.
    func linear(_ installation: String, subject: String? = nil) -> [DoctorFinding] {
        filter {
            $0.check == .linear && $0.installation?.name == installation && (subject == nil || $0.subject == subject)
        }
    }
}
