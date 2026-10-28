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
    additionalReadableDirectories: [String] = ["/repos/extra-readable"],
    provenance: DispatchProvenance? = nil
) -> AgentDispatchRequest {
    let repo = Repo(name: "backend", path: "/repos/backend", role: .backend)
    let instruction = Instruction(
        pass: pass, card: InstructionCard(key: "BACK-1", title: "BACK-1"),
        brief: ArchitecturalBrief(prose: "", transcriptions: []), definitionOfDone: [],
        repository: InstructionRepository(
            repo: repo, worktreePath: "/wt/backend", featureBranch: "yh-proj-feat", check: .none
        ),
        route: route, payloads: .none
    )
    return AgentDispatchRequest(
        runID: RunID(rawValue: "run-1")!, issueID: "BACK-1", attemptID: 7, route: route, pass: pass,
        instruction: .card(instruction), worktreePath: "/wt/backend", resumeSession: resumeSession,
        additionalReadableDirectories: additionalReadableDirectories,
        additionalWritableDirectories: ["/repos/backend/.git"],
        provenance: provenance
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
        exists: @escaping @Sendable (String) -> Bool = { _ in false },
        protectedDirectories: [String] = []
    ) -> CLIAdapterDispatch {
        CLIAdapterDispatch(
            runsDirectory: runs, timeout: .seconds(90), declaredExecutables: declared, path: path,
            environment: ["HOME": "/home/operator"], fileExists: exists,
            protectedDirectories: protectedDirectories
        )
    }

    @Test("The dispatch carries the protected directories onto the CLI dispatch (issue #546)")
    func dispatchCarriesProtectedDirectories() {
        let protected = ["/config", "/home/operator/Library/Keychains"]
        let mapped = makeDispatch(protectedDirectories: protected)
            .makeDispatch(for: request(), executable: "/bin/claude")
        #expect(mapped.protectedDirectories == protected)
        #expect(makeDispatch().makeDispatch(for: request(), executable: "/bin/claude").protectedDirectories == [])
    }

    @Test("The protected directories are the configuration directory and the login Keychains, absolute")
    func protectedDirectoriesAreAbsolute() {
        let configuration = URL(filePath: "/Users/operator/.config/yellowhammer", directoryHint: .isDirectory)
        let directories = CLIAdapterDispatch.protectedDirectories(configurationDirectory: configuration)
        #expect(directories.count == 2)
        #expect(directories.first == "/Users/operator/.config/yellowhammer")
        let keychains = directories.last ?? ""
        #expect(keychains.hasPrefix("/"))
        #expect(keychains.hasSuffix("/Library/Keychains"))
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
        // The pass is not told where the adapter persists the response it validates (issue #546).
        #expect(!mapped.instruction.contains("/config/runs/proj/run-1/BACK-1/7-worker"))
        #expect(!mapped.instruction.contains("result.json"))
    }

    @Test("The text handed to the CLI keeps the worker's commit-message request after the result file is stamped")
    func stampedInstructionKeepsTheCommitMessageRequest() throws {
        // Night 2026-10-12 (and #437 before it): the stamped copy dropped the request, so no worker ever
        // saw the `## Commit messages` section and every commit lacked the Yellowhammer-Work-Card trailer.
        let worker = request()
        let instruction = try #require(worker.instruction.cardInstruction)
        let withRequest = Instruction(
            pass: .worker, card: instruction.card, brief: instruction.brief,
            definitionOfDone: instruction.definitionOfDone, repository: instruction.repository,
            route: instruction.route, payloads: instruction.payloads,
            commitMessage: CommitMessageRequest(message: "feat(auth): BACK-1 [YLH-7] backend", workCardKey: "YLH-7")
        )
        let stamped = AgentDispatchRequest(
            runID: worker.runID, issueID: worker.issueID, attemptID: worker.attemptID, route: worker.route,
            pass: .worker, instruction: .card(withRequest), worktreePath: worker.worktreePath,
            resumeSession: nil, additionalReadableDirectories: worker.additionalReadableDirectories,
            additionalWritableDirectories: worker.additionalWritableDirectories
        )

        let mapped = makeDispatch().makeDispatch(for: stamped, executable: "/bin/claude")

        #expect(mapped.instruction.contains("## Commit messages"))
        #expect(mapped.instruction.contains("    feat(auth): BACK-1 [YLH-7] backend\n"))
        #expect(mapped.instruction.contains("Yellowhammer-Work-Card: YLH-7"))
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

    @Test("A CLIAdapterDispatch refusal when no adapter exists captures a not-launched record with nil outputSchema")
    func refusalNoAdapterCapturesRecord() async throws {
        let recorder = FakePromptRecorder()
        let dispatch = CLIAdapterDispatch(
            runsDirectory: runs,
            declaredExecutables: ["claude": "/bin/true"],
            recorder: recorder
        )
        let unknown = Route(cli: "unknown-cli", model: "model", effort: "high")!
        let provenance = DispatchProvenance(
            recordID: "rec-no-adapter", family: .worker, projectID: "proj-1", runID: "run-1", nightID: 1
        )
        var req = request(route: unknown)
        req.provenance = provenance

        await #expect(throws: AgentDispatchRefusal.self) {
            try await dispatch.dispatch(req)
        }

        #expect(recorder.captured.count == 1)
        let record = try #require(recorder.captured.first)
        #expect(record.id == "rec-no-adapter")
        #expect(record.outputSchema == nil)
        guard case .notLaunched(let cause) = record.launch else {
            Issue.record("expected .notLaunched, got \(record.launch)")
            return
        }
        #expect(cause.contains("no CLI Adapter"))
    }

    @Test(
        "A CLIAdapterDispatch refusal when executable is unresolvable captures not-launched record with outputSchema"
    )
    func refusalNoExecutableCapturesRecord() async throws {
        let recorder = FakePromptRecorder()
        let dispatch = CLIAdapterDispatch(
            runsDirectory: runs,
            path: "/nowhere",
            recorder: recorder
        )
        let provenance = DispatchProvenance(
            recordID: "rec-no-exec", family: .worker, projectID: "proj-1", runID: "run-1", nightID: 1
        )
        var req = request()
        req.provenance = provenance

        await #expect(throws: AgentDispatchRefusal.self) {
            try await dispatch.dispatch(req)
        }

        #expect(recorder.captured.count == 1)
        let record = try #require(recorder.captured.first)
        #expect(record.id == "rec-no-exec")
        let schema = try #require(record.outputSchema)
        #expect(!schema.isEmpty)
        guard case .notLaunched(let cause) = record.launch else {
            Issue.record("expected .notLaunched, got \(record.launch)")
            return
        }
        #expect(cause.contains("no executable found"))
    }

    @Test("An unavailable recorder leaves the refusal outcome unchanged")
    func unavailableRecorderLeavesRefusalUnchanged() async throws {
        let recorder = FakePromptRecorder()
        recorder.captureResult = .unavailable(cause: "disk full")
        let dispatch = CLIAdapterDispatch(
            runsDirectory: runs,
            path: "/nowhere",
            recorder: recorder
        )
        let provenance = DispatchProvenance(
            recordID: "rec-unavail", family: .worker, projectID: "proj-1", runID: "run-1", nightID: 1
        )
        var req = request()
        req.provenance = provenance

        await #expect(throws: AgentDispatchRefusal.self) {
            try await dispatch.dispatch(req)
        }
    }
}

@Suite("Agent CLI dispatch: Project instructions")
struct ProjectInstructionsDispatchTests {
    private let runs = URL(filePath: "/config/runs/proj", directoryHint: .isDirectory)

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(component: "yh-dispatch-instructions-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func store(_ root: URL, project: String) throws -> ProjectInstructionsStore {
        ProjectInstructionsStore(rootDirectory: root, projectID: try #require(ProjectID(rawValue: project)))
    }

    /// A dispatch whose executable cannot be resolved, so it refuses after composing: the recorded refusal
    /// holds exactly the text that would have been sent.
    private func dispatch(
        _ store: ProjectInstructionsStore?, recorder: FakePromptRecorder
    ) -> CLIAdapterDispatch {
        CLIAdapterDispatch(runsDirectory: runs, path: "/nowhere", recorder: recorder, projectInstructions: store)
    }

    private func provenanced(
        _ id: String, pass: RunPass = .worker, resumeSession: String? = nil, projectID: String = "proj"
    ) -> AgentDispatchRequest {
        var req = request(pass: pass, resumeSession: resumeSession)
        req.provenance = DispatchProvenance(
            recordID: id, family: PromptFamily(pass: pass)!, projectID: projectID, runID: "run-1", nightID: 1
        )
        return req
    }

    @Test("An absent store records absent and leaves the instruction unchanged")
    func absentStore() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for store in [nil, try store(root, project: "proj")] {
            let recorder = FakePromptRecorder()
            await #expect(throws: AgentDispatchRefusal.self) {
                try await dispatch(store, recorder: recorder).dispatch(provenanced("rec-absent"))
            }
            let record = try #require(recorder.captured.first)
            #expect(record.projectInstructions == .absent)
            #expect(record.instruction == request().instruction.render())
        }
    }

    @Test("A saved revision composes its text and records the revision id")
    func savedRevision() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root, project: "proj")
        guard case .saved(let revision) = store.save("Prefer small commits.", replacing: .absent) else {
            Issue.record("expected a saved revision")
            return
        }
        let recorder = FakePromptRecorder()
        let seam = dispatch(store, recorder: recorder)

        await #expect(throws: AgentDispatchRefusal.self) { try await seam.dispatch(provenanced("rec-saved")) }

        let record = try #require(recorder.captured.first)
        #expect(record.projectInstructions == .revision(revision.id))
        #expect(record.instruction == request().instruction.render(projectInstructions: "Prefer small commits."))
        let resolved = seam.resolveProjectInstructions(for: request())
        let mapped = seam.makeDispatch(for: request(), executable: "/bin/claude", resolved: resolved)
        #expect(mapped.projectInstructions == .revision(revision.id))
        #expect(mapped.instruction == record.instruction)
    }

    @Test("A save between two dispatches reaches the second, and only the second")
    func saveBetweenDispatches() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root, project: "proj")
        let recorder = FakePromptRecorder()
        let seam = dispatch(store, recorder: recorder)
        guard case .saved(let first) = store.save("First.", replacing: .absent) else {
            Issue.record("expected a saved revision")
            return
        }
        await #expect(throws: AgentDispatchRefusal.self) { try await seam.dispatch(provenanced("rec-1")) }
        guard case .saved(let second) = store.save("Second.", replacing: .revision(first.id)) else {
            Issue.record("expected a saved revision")
            return
        }
        await #expect(throws: AgentDispatchRefusal.self) { try await seam.dispatch(provenanced("rec-2", resumeSession: "same-worker")) }

        let records = recorder.captured
        #expect(records.map(\.projectInstructions) == [.revision(first.id), .revision(second.id)])
        #expect(records.map(\.session) == [.new, .resumed])
        #expect(records[0].instruction.contains("First.") && !records[0].instruction.contains("Second."))
        #expect(records[1].instruction.contains("Second.") && !records[1].instruction.contains("First."))
    }

    @Test("Unreadable saved instructions refuse the dispatch as not launched, with no supplement")
    func unavailableRefuses() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root, project: "proj")
        guard case .saved = store.save("Secret rules.", replacing: .absent) else {
            Issue.record("expected a saved revision")
            return
        }
        let file = root.standardizedFileURL.appending(
            components: "projects", "proj", "instructions", "current.json", directoryHint: .notDirectory
        )
        try Data("not json".utf8).write(to: file)
        let recorder = FakePromptRecorder()

        let refusal = await #expect(throws: AgentDispatchRefusal.self) {
            try await dispatch(store, recorder: recorder).dispatch(provenanced("rec-unavailable"))
        }

        #expect(refusal?.reason.contains("saved instructions could not be used") == true)
        #expect(refusal?.reason.contains("Settings → Configuration → Prompts") == true)
        let record = try #require(recorder.captured.first)
        guard case .unavailable(let cause) = record.projectInstructions else {
            Issue.record("expected .unavailable, got \(record.projectInstructions)")
            return
        }
        #expect(refusal?.reason.contains(cause) == true)
        guard case .notLaunched = record.launch else {
            Issue.record("expected .notLaunched, got \(record.launch)")
            return
        }
        #expect(!record.instruction.contains("Secret rules."))
        #expect(record.instruction == request().instruction.render())
    }

    @Test("Another Project's saved instructions never reach this dispatch")
    func otherProjectIsolated() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectA = try store(root, project: "project-a")
        let projectB = try store(root, project: "project-b")
        guard case .saved = projectA.save("Only for A.", replacing: .absent) else {
            Issue.record("expected a saved revision")
            return
        }
        let recorder = FakePromptRecorder()

        await #expect(throws: AgentDispatchRefusal.self) {
            try await dispatch(projectB, recorder: recorder).dispatch(provenanced("rec-b", projectID: "project-b"))
        }

        let record = try #require(recorder.captured.first)
        #expect(record.projectInstructions == .absent)
        #expect(!record.instruction.contains("Only for A."))
    }
}

private final class FakePromptRecorder: DispatchPromptRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var _captured: [DispatchPromptRecord] = []
    private var _launches: [(launch: DispatchLaunch, record: DispatchPromptRecord)] = []
    var captureResult: DispatchPromptCapture = .recorded(id: "fake-id")

    var captured: [DispatchPromptRecord] {
        lock.lock()
        defer { lock.unlock() }
        return _captured
    }

    var launches: [(launch: DispatchLaunch, record: DispatchPromptRecord)] {
        lock.lock()
        defer { lock.unlock() }
        return _launches
    }

    func capture(_ record: DispatchPromptRecord) -> DispatchPromptCapture {
        lock.lock()
        _captured.append(record)
        lock.unlock()
        return captureResult
    }

    func markLaunch(_ launch: DispatchLaunch, of record: DispatchPromptRecord) -> Bool {
        lock.lock()
        _launches.append((launch, record))
        lock.unlock()
        return true
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

            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"

            [cli.claude]
            executable = "/opt/claude"
            """, file: "config.toml")
        let project = ProjectConfiguration(
            id: projectID, name: "P", linearInstallationName: "acme", linearProject: "P",
            codeHostingConnectionName: "github",
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
        #expect(cli.projectInstructions?.projectID == projectID)
        #expect(
            cli.projectInstructions?.rootDirectory
                == DispatchPromptStore.rootDirectory(configurationDirectory: directory).standardizedFileURL
        )
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
