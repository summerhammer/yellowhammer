import Config
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Ledger
import Testing

// The Dispatch seam and the Check seam (roadmap P8.4). Nothing here spawns an agent CLI: a Rehearsal Night
// never dispatches one, and the real seam's mapping and refusals are exercised up to the spawn.

private let dispatchOpus = Route(cli: "claude", model: "opus", effort: "high")!

private func request(
    route: Route = dispatchOpus, pass: RunPass = .worker, resumeSession: String? = nil,
    additionalReadableDirectories: [String] = ["/repos/extra-readable"]
) -> AgentDispatchRequest {
    let repo = Repo(name: "backend", path: "/repos/backend", role: .backend)
    let instruction = Instruction(
        pass: pass, card: InstructionCard(key: "BACK-1", title: "BACK-1"),
        brief: ArchitecturalBrief(prose: "", transcriptions: []), definitionOfDone: [],
        repository: InstructionRepository(
            repo: repo, worktreePath: "/wt/backend", featureBranch: "yh-proj-feat", check: .none
        ),
        route: route, payloads: .none, resultFilePath: ""
    )
    return AgentDispatchRequest(
        runID: RunID(rawValue: "run-1")!, issueID: "BACK-1", attemptID: 7, route: route, pass: pass,
        instruction: .card(instruction), worktreePath: "/wt/backend", resumeSession: resumeSession,
        additionalReadableDirectories: additionalReadableDirectories,
        additionalWritableDirectories: ["/repos/backend/.git"]
    )
}

@Suite("Rehearsal dispatch")
struct RehearsalDispatchTests {
    @Test("A Rehearsal Night answers each pass from the fixtures and spawns nothing: architect, worker, reviewer")
    func answersEachPassFromTheFixtures() async throws {
        let rehearsal = RehearsalDispatch()

        let architect = try await rehearsal.dispatch(request(pass: .architect))
        let worker = try await rehearsal.dispatch(request(pass: .worker))
        let reviewer = try await rehearsal.dispatch(request(pass: .reviewer))

        #expect(architect.outcome == RehearsalResultFixture.architectPlanned.outcome())
        #expect(worker.outcome == RehearsalResultFixture.workerCompleted.outcome())
        #expect(reviewer.outcome == RehearsalResultFixture.reviewerApproved.outcome())
        #expect([architect, worker, reviewer].allSatisfy { $0.session == nil })
        #expect(rehearsal.answered.map(\.pass) == [.architect, .worker, .reviewer])
    }

    @Test("A pass can be scripted to a failure fixture, and the others keep their defaults")
    func scriptedPassAnswersFromItsFixture() async throws {
        let rehearsal = RehearsalDispatch(script: [.worker: .workerEmpty])

        let worker = try await rehearsal.dispatch(request(pass: .worker))
        let architect = try await rehearsal.dispatch(request(pass: .architect))

        guard case .crashedUnknown(.resultFile) = worker.outcome else {
            Issue.record("expected an empty worker result to be Crashed-Unknown, got \(worker.outcome)")
            return
        }
        #expect(architect.outcome == RehearsalResultFixture.architectPlanned.outcome())
    }
}

@Suite("Agent CLI dispatch")
struct CLIAdapterDispatchTests {
    private let runs = URL(filePath: "/config/runs/proj", directoryHint: .isDirectory)

    private func makeDispatch(
        declared: [String: String] = [:], path: String? = nil,
        exists: @escaping @Sendable (String) -> Bool = { _ in false }
    ) -> CLIAdapterDispatch {
        CLIAdapterDispatch(
            runsDirectory: runs, timeout: .seconds(90), declaredExecutables: declared, path: path,
            environment: ["HOME": "/home/operator"], fileExists: exists
        )
    }

    @Test("A request maps onto the agent CLI dispatch: a run directory outside the Worktree holds the result file")
    func requestMapsOntoTheAgentCLIDispatch() throws {
        let dispatch = makeDispatch()

        let mapped = dispatch.makeDispatch(
            for: request(resumeSession: "session-abc"), executable: "/usr/local/bin/claude"
        )

        #expect(mapped.route == dispatchOpus)
        #expect(mapped.pass == .worker)
        #expect(mapped.worktreePath == "/wt/backend")
        #expect(mapped.timeout == .seconds(90))
        #expect(mapped.resume?.rawValue == "session-abc")
        #expect(mapped.additionalReadableDirectories == ["/repos/extra-readable"])
        #expect(mapped.additionalWritableDirectories == ["/repos/backend/.git"])
        #expect(mapped.executable == "/usr/local/bin/claude")
        #expect(mapped.environment == ["HOME": "/home/operator"])
        #expect(
            mapped.runDirectory
                == URL(filePath: "/config/runs/proj/run-1/BACK-1/7-worker", directoryHint: .isDirectory)
        )
        #expect(!mapped.runDirectory.path(percentEncoded: false).hasPrefix("/wt/backend"))
        // What the agent is told to write is what the adapter's dual-key check reads back.
        #expect(mapped.instruction.contains("/config/runs/proj/run-1/BACK-1/7-worker/result.json"))
    }

    @Test("A pass with no session to resume starts a fresh one")
    func noSessionMeansNoResume() {
        let mapped = makeDispatch().makeDispatch(for: request(), executable: "/bin/claude")

        #expect(mapped.resume == nil)
    }

    @Test("A Route naming a CLI with no adapter is refused, not an engine fault, and nothing is spawned")
    func unknownCLIIsRefused() async throws {
        let unknown = Route(cli: "gemini", model: "pro", effort: "high")!

        await #expect(throws: AgentDispatchRefusal.self) {
            try await makeDispatch(declared: ["gemini": "/bin/true"]).dispatch(request(route: unknown))
        }
    }

    @Test("A CLI whose executable cannot be found is refused")
    func unresolvableExecutableIsRefused() async throws {
        await #expect(throws: AgentDispatchRefusal.self) {
            try await makeDispatch(path: "/nowhere:/nothing").dispatch(request())
        }
    }

    @Test("An effort the adapter does not accept is refused before anything is spawned")
    func unsupportedEffortIsRefused() async throws {
        let bogus = Route(cli: "claude", model: "opus", effort: "ludicrous")!
        let dispatch = makeDispatch(declared: ["claude": "/bin/true"])

        await #expect(throws: AgentDispatchRefusal.self) {
            try await dispatch.dispatch(request(route: bogus))
        }
    }

    @Test("A declared executable wins over the PATH search")
    func declaredExecutableWins() {
        #expect(
            ProbeExecutable.resolve(
                name: "claude", declared: "/opt/claude", path: "/usr/bin", fileExists: { _ in true }
            ) == "/opt/claude"
        )
    }
}

@Suite("Card run binding")
struct CardRunBindingTests {
    private func configuration(projectID: ProjectID) throws -> (Configuration, ProjectConfiguration) {
        let machine = try MachineConfiguration.parse("""
            [board.linear.connections.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"

            [github]
            credential = "keychain:github"

            [cli.claude]
            executable = "/opt/claude"
            """, file: "config.toml")
        let project = ProjectConfiguration(
            id: projectID, name: "P", linearInstallationName: "acme", linearProject: "P",
            repos: [
                RepoDeclaration(name: "backend", path: "/repos/backend", role: .backend, check: .none),
                RepoDeclaration(name: "mobile", path: "/repos/mobile", role: .mobile, check: .command("make test"))
            ]
        )
        let table = RoutingTable(entries: [RoutingEntry(route: dispatchOpus)])
        return (
            Configuration(
                machine: machine, projects: [project], invalidProjects: [], routingTables: [projectID: table]
            ),
            project
        )
    }

    @Test("A Rehearsal Night is wired to the rehearsal fixtures; a real Night to the agent CLI adapters")
    func modeChoosesTheDispatch() throws {
        let projectID = try #require(ProjectID(rawValue: "proj"))
        let (configuration, project) = try configuration(projectID: projectID)
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-cardrun-binding-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rehearsal = try CardRunBinding.cardRunner(
            mode: .rehearsal, configuration: configuration, project: project, configurationDirectory: directory
        )
        let real = try CardRunBinding.cardRunner(
            mode: .real, configuration: configuration, project: project, configurationDirectory: directory
        )

        #expect(rehearsal.dispatch is RehearsalDispatch)
        #expect(real.dispatch is CLIAdapterDispatch)
        #expect(real.checks == ["backend": .none, "mobile": .command("make test")])
        let cli = try #require(real.dispatch as? CLIAdapterDispatch)
        #expect(cli.declaredExecutables == ["claude": "/opt/claude"])
        #expect(cli.runsDirectory == directory.appending(components: "runs", "proj", directoryHint: .isDirectory))
    }

    @Test("A rehearsal Night's Dispatch answers a scripted pass from its scripted fixture (roadmap P15.2)")
    func rehearsalDispatchAnswersScriptedFixture() async throws {
        let projectID = try #require(ProjectID(rawValue: "proj"))
        let (configuration, project) = try configuration(projectID: projectID)
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-cardrun-binding-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dispatch = DispatchBinding.dispatch(
            mode: .rehearsal, configuration: configuration, project: project, configurationDirectory: directory,
            resultFixtures: [.worker: .workerQuestion]
        )

        let report = try await dispatch.dispatch(request(pass: .worker))

        #expect(report.outcome == RehearsalResultFixture.workerQuestion.outcome())
        #expect(report.origin == .rehearsalFixture(RehearsalResultFixture.workerQuestion.rawValue))
    }
}
