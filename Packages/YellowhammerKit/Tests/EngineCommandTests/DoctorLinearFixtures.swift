import Domain
import Engine
@testable import EngineCommand
import Foundation
import Journal
import Testing

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
        provisionAcme: Bool = true, projectExtras: [String: String] = [:]
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
                \(projectExtras[project.id] ?? "")
                """)
        }
        acme = await Self.board(workspaceName: "Acme Inc", project: "lp-alpha", provisioned: provisionAcme)
        globex = await Self.board(workspaceName: "Globex Corp", project: "lp-beta")
        if provisionAcme {
            await Self.recordSetup(
                of: acme, project: "lp-alpha", in: directory.url,
                for: projects.filter { $0.installation == "acme" }.map(\.id), workspace: "ws-acme"
            )
        }
        await Self.recordSetup(
            of: globex, project: "lp-beta", in: directory.url,
            for: projects.filter { $0.installation == "globex" }.map(\.id), workspace: "ws-globex"
        )
    }

    /// What `yh setup` does for a Project's board: provision it and record the ids it resolved in the
    /// Project's own Journal, so a later `yh doctor` finds them and never adopts a state by name.
    /// Projects sharing the board are each given the ids, as if each had been mapped to them.
    static func recordSetup(
        of board: FakeProvisioningBoard, project: String, in directory: URL, for projects: [String], workspace: String
    ) async {
        do {
            let report = try await BoardProvisioner.provision(
                using: board, projectName: project, createIn: nil,
                footprint: BoardFootprintInputs(store: InMemoryBoardFootprintStore())
            )
            for id in projects {
                guard let projectID = ProjectID(rawValue: id) else { continue }
                let journal = try JournalStore.open(
                    configurationDirectory: directory, projectID: projectID,
                    linearWorkspace: BoardObjectID(rawValue: workspace)
                )
                try journal.recordBoardFootprint(report.footprint)
            }
        } catch {
            Issue.record("fixture setup could not provision \(project): \(error)")
        }
    }

    static func board(workspaceName: String, project: String, provisioned: Bool = true) async -> FakeProvisioningBoard {
        let scope = BoardProjectScope(id: BoardObjectID(rawValue: project), name: project, teams: [engineeringTeam])
        let board = await makeBoard(project: scope, members: [operatorMember])
        await board.setWorkspace(BoardWorkspace(
            id: "ws-\(project == "lp-alpha" ? "acme" : "globex")", name: workspaceName, urlKey: "ws",
            viewer: BoardIdentity(
                id: BoardObjectID(rawValue: "app-user-\(project == "lp-alpha" ? "acme" : "globex")"),
                name: "yellowhammer", displayName: "Yellowhammer"
            )
        ))
        // The native states Linear gives every team, provisioned or not: setup selects them by category and
        // never creates one.
        await board.seed(state: "Todo", team: engineeringTeam.id, category: .unstarted)
        await board.seed(state: "In Progress", team: engineeringTeam.id, category: .started)
        await board.seed(state: "Done", team: engineeringTeam.id, category: .completed)
        await board.seed(state: "Canceled", team: engineeringTeam.id, category: .shelved)
        return board
    }

    static let credentials = RecordingCredentialStore(seed: [
        "keychain:linear-acme": "secret", "keychain:linear-globex": "secret"
    ])

    func doctor(
        credentials: RecordingCredentialStore = DoctorLinearFixture.credentials,
        output: RecordingOutput = RecordingOutput(), checks: [DoctorCheck] = [.configuration, .linear],
        projectFilter: ProjectID? = nil, fix: Bool = false
    ) -> Doctor {
        makeDoctor(
            directory: directory, boards: ["acme": acme, "globex": globex], binds: binds, credentials: credentials,
            output: output, fix: fix, checks: checks, projectFilter: projectFilter
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
