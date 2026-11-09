import Config
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Testing

@Suite("AgentDispatch foreign turns Port tests")
struct AgentDispatchForeignTurnsTests {

    private struct Fixture {
        let tempDir: URL
        let configDir: URL
        let projectsDir: URL
        let worktreeDir: URL
        let runsDir: URL

        static func make() throws -> Fixture {
            let tempDir = FileManager.default.temporaryDirectory
                .appending(component: "yh-port-turns-\(UUID().uuidString)", directoryHint: .isDirectory)
            let configDir = tempDir.appending(component: "claude-config", directoryHint: .isDirectory)
            let projectsDir = configDir.appending(component: "projects", directoryHint: .isDirectory)
            let worktreeDir = tempDir.appending(component: "worktree", directoryHint: .isDirectory)
            let runsDir = tempDir.appending(component: "runs", directoryHint: .isDirectory)

            let fileManager = FileManager.default
            try fileManager.createDirectory(at: projectsDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: worktreeDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: runsDir, withIntermediateDirectories: true)

            return Fixture(
                tempDir: tempDir, configDir: configDir, projectsDir: projectsDir,
                worktreeDir: worktreeDir, runsDir: runsDir
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: tempDir)
        }

        func writeTranscript(sessionID: String, lines: [String]) throws {
            let encodedCwd = String(worktreeDir.path(percentEncoded: false).map { character in
                character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
            })
            let projectDir = projectsDir.appending(component: encodedCwd, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let file = projectDir.appending(component: "\(sessionID).jsonl")
            let content = lines.map { $0 + "\n" }.joined()
            try Data(content.utf8).write(to: file)
        }

        func writeMarker(runID: RunID, issueID: String, attemptID: Int64, pass: RunPass, uuid: String) throws {
            let runDirectory = CLIAdapterDispatch.runDirectory(
                runsDirectory: runsDir, runID: runID, issueID: issueID, attemptID: attemptID, pass: pass
            )
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            let file = runDirectory.appending(component: ".last-message-id")
            try uuid.write(to: file, atomically: true, encoding: .utf8)
        }

        func makeDispatch() -> CLIAdapterDispatch {
            CLIAdapterDispatch(
                runsDirectory: runsDir,
                environment: ["CLAUDE_CONFIG_DIR": configDir.path(percentEncoded: false)]
            )
        }

        func makeRequest(
            route: Route, resumeSession: String? = nil, runID: String = "run-1",
            issueID: String = "BACK-1", attemptID: Int64 = 1, pass: RunPass = .worker
        ) -> AgentDispatchRequest {
            let repo = Repo(name: "backend", path: worktreeDir.path(percentEncoded: false), role: .backend)
            let instruction = Instruction(
                pass: pass, card: InstructionCard(key: issueID, title: issueID),
                brief: ArchitecturalBrief(prose: "", transcriptions: []), definitionOfDone: [],
                repository: InstructionRepository(
                    repo: repo, worktreePath: worktreeDir.path(percentEncoded: false),
                    featureBranch: "yh-proj-feat", check: .none
                ),
                route: route, payloads: .none
            )
            return AgentDispatchRequest(
                runID: RunID(rawValue: runID)!, issueID: issueID, attemptID: attemptID, route: route, pass: pass,
                instruction: .card(instruction), worktreePath: worktreeDir.path(percentEncoded: false),
                resumeSession: resumeSession
            )
        }
    }

    @Test("Dispatch Port reports foreign turns for touched resumed session")
    func dispatchReportsForeignTurnsForTouchedSession() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let sessionID = "sess-touched"
        try fixture.writeTranscript(sessionID: sessionID, lines: [
            #"{"type":"user","uuid":"u1","entrypoint":"cli","message":"manual turn"}"#,
            #"{"type":"assistant","uuid":"a1","message":"answer"}"#
        ])
        let route = Route(cli: "claude", model: "sonnet", effort: "high")!
        let request = fixture.makeRequest(route: route, resumeSession: sessionID)

        let dispatch = fixture.makeDispatch()
        let hasForeign = await dispatch.foreignTurns(before: request)
        #expect(hasForeign)
    }

    @Test("Dispatch Port reports false for untouched resumed session")
    func dispatchReportsFalseForUntouchedSession() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let sessionID = "sess-untouched"
        let runID = RunID(rawValue: "run-1")!
        try fixture.writeTranscript(sessionID: sessionID, lines: [
            #"{"type":"user","uuid":"u1","entrypoint":"sdk-cli"}"#,
            #"{"type":"assistant","uuid":"a1"}"#
        ])
        try fixture.writeMarker(runID: runID, issueID: "BACK-1", attemptID: 1, pass: .worker, uuid: "a1")

        let route = Route(cli: "claude", model: "sonnet", effort: "high")!
        let request = fixture.makeRequest(route: route, resumeSession: sessionID)

        let dispatch = fixture.makeDispatch()
        let hasForeign = await dispatch.foreignTurns(before: request)
        #expect(!hasForeign)
    }

    @Test("Dispatch Port reports false when request has no resume session")
    func dispatchReportsFalseWithNoResumeSession() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let route = Route(cli: "claude", model: "sonnet", effort: "high")!
        let request = fixture.makeRequest(route: route, resumeSession: nil)

        let dispatch = fixture.makeDispatch()
        let hasForeign = await dispatch.foreignTurns(before: request)
        #expect(!hasForeign)
    }

    @Test("Dispatch Port reports false for unregistered CLI without failing")
    func dispatchReportsFalseForUnregisteredCLI() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let route = Route(cli: "nonexistent", model: "some-model", effort: "medium")!
        let request = fixture.makeRequest(route: route, resumeSession: "some-session")

        let dispatch = fixture.makeDispatch()
        let hasForeign = await dispatch.foreignTurns(before: request)
        #expect(!hasForeign)
    }

    @Test("Dispatch Port reports false for Codex and Antigravity routes")
    func dispatchReportsFalseForCodexAndAntigravity() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let codexRoute = Route(cli: "codex", model: "gpt-5.5", effort: "high")!
        let agyRoute = Route(cli: "agy", model: "gemini-3.8-flash", effort: "high")!

        let dispatch = fixture.makeDispatch()
        let codexRequest = fixture.makeRequest(route: codexRoute, resumeSession: "codex-session")
        let agyRequest = fixture.makeRequest(route: agyRoute, resumeSession: "agy-session")

        #expect(!(await dispatch.foreignTurns(before: codexRequest)))
        #expect(!(await dispatch.foreignTurns(before: agyRequest)))
    }

    @Test("RehearsalDispatch answers false for foreignTurns")
    func rehearsalDispatchAnswersFalse() async throws {
        let rehearsal = RehearsalDispatch()
        let route = Route(cli: "claude", model: "sonnet", effort: "high")!
        let repo = Repo(name: "backend", path: "/repos/backend", role: .backend)
        let instruction = Instruction(
            pass: .worker, card: InstructionCard(key: "BACK-1", title: "BACK-1"),
            brief: ArchitecturalBrief(prose: "", transcriptions: []), definitionOfDone: [],
            repository: InstructionRepository(
                repo: repo, worktreePath: "/wt/backend", featureBranch: "yh-proj-feat", check: .none
            ),
            route: route, payloads: .none
        )
        let request = AgentDispatchRequest(
            runID: RunID(rawValue: "run-1")!, issueID: "BACK-1", attemptID: 1, route: route, pass: .worker,
            instruction: .card(instruction), worktreePath: "/wt/backend", resumeSession: "prior-session"
        )
        #expect(!(await rehearsal.foreignTurns(before: request)))
    }
}
