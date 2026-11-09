@testable import CLIAdapters
import Domain
import Foundation
import Testing

@Suite("ClaudeCodeAdapter foreign turns detection")
struct ClaudeCodeAdapterForeignTurnsTests {

    private struct Fixture {
        let tempDir: URL
        let configDir: URL
        let projectsDir: URL
        let worktreeDir: URL
        let runDir: URL

        static func make() throws -> Fixture {
            let tempDir = FileManager.default.temporaryDirectory
                .appending(component: "yh-foreign-turns-\(UUID().uuidString)", directoryHint: .isDirectory)
            let configDir = tempDir.appending(component: "claude-config", directoryHint: .isDirectory)
            let projectsDir = configDir.appending(component: "projects", directoryHint: .isDirectory)
            let worktreeDir = tempDir.appending(component: "worktree", directoryHint: .isDirectory)
            let runDir = tempDir.appending(component: "run", directoryHint: .isDirectory)

            let fileManager = FileManager.default
            try fileManager.createDirectory(at: projectsDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: worktreeDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: runDir, withIntermediateDirectories: true)

            return Fixture(
                tempDir: tempDir, configDir: configDir, projectsDir: projectsDir,
                worktreeDir: worktreeDir, runDir: runDir
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: tempDir)
        }

        func writeTranscript(sessionID: String, lines: [String], customEncodedCwd: String? = nil) throws {
            let encodedCwd = customEncodedCwd ?? ClaudeCodeAdapter.encodeWorktreePath(
                worktreeDir.path(percentEncoded: false)
            )
            let projectDir = projectsDir.appending(component: encodedCwd, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let file = projectDir.appending(component: "\(sessionID).jsonl")
            let content = lines.map { $0 + "\n" }.joined()
            try Data(content.utf8).write(to: file)
        }

        func writeMarker(_ uuid: String) throws {
            let file = runDir.appending(component: ".last-message-id")
            try uuid.write(to: file, atomically: true, encoding: .utf8)
        }

        func dispatch(resume: CLISession? = nil) -> CLIDispatch {
            let route = Route(cli: "claude", model: "sonnet", effort: "high")!
            return CLIDispatch(
                route: route,
                pass: .worker,
                instruction: "implement feature",
                worktreePath: worktreeDir.path(percentEncoded: false),
                runDirectory: runDir,
                timeout: .seconds(5),
                resume: resume,
                additionalReadableDirectories: [],
                additionalWritableDirectories: [],
                protectedDirectories: [],
                executable: "/bin/echo",
                environment: ["CLAUDE_CONFIG_DIR": configDir.path(percentEncoded: false)]
            )
        }
    }

    @Test("Interactive CLI user record with entrypoint cli reports foreign turns")
    func interactiveCLIUserRecordReportsForeignTurns() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let sessionID = "sess-1"
        try fixture.writeTranscript(sessionID: sessionID, lines: [
            #"{"type":"user","uuid":"u1","entrypoint":"cli","message":"hello"}"#,
            #"{"type":"assistant","uuid":"a1","message":"hi"}"#
        ])
        try fixture.writeMarker("a1")

        let adapter = ClaudeCodeAdapter(configDirectory: fixture.configDir)
        let dispatch = fixture.dispatch(resume: CLISession(rawValue: sessionID))
        #expect(adapter.foreignTurns(before: dispatch))
    }

    @Test("Assistant record after the recorded marker reports foreign turns")
    func assistantRecordAfterMarkerReportsForeignTurns() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let sessionID = "sess-2"
        try fixture.writeTranscript(sessionID: sessionID, lines: [
            #"{"type":"user","uuid":"u1","entrypoint":"sdk-cli"}"#,
            #"{"type":"assistant","uuid":"a1"}"#,
            #"{"type":"assistant","uuid":"a2"}"#
        ])
        try fixture.writeMarker("a1")

        let adapter = ClaudeCodeAdapter(configDirectory: fixture.configDir)
        let dispatch = fixture.dispatch(resume: CLISession(rawValue: sessionID))
        #expect(adapter.foreignTurns(before: dispatch))
    }

    @Test("Only non-turn records after marker never count as foreign turns")
    func nonTurnRecordsAfterMarkerDoNotReportForeignTurns() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let sessionID = "sess-3"
        try fixture.writeTranscript(sessionID: sessionID, lines: [
            #"{"type":"user","uuid":"u1","entrypoint":"sdk-cli"}"#,
            #"{"type":"assistant","uuid":"a1"}"#,
            #"{"type":"session-owner","uuid":"so1"}"#,
            #"{"type":"queue-operation","uuid":"qo1"}"#,
            #"{"type":"custom-title","uuid":"ct1"}"#
        ])
        try fixture.writeMarker("a1")

        let adapter = ClaudeCodeAdapter(configDirectory: fixture.configDir)
        let dispatch = fixture.dispatch(resume: CLISession(rawValue: sessionID))
        #expect(!adapter.foreignTurns(before: dispatch))
    }

    @Test("Only sdk-cli turns up to the marker reports false")
    func onlySDKCLITurnsUpToMarkerReportsFalse() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let sessionID = "sess-4"
        try fixture.writeTranscript(sessionID: sessionID, lines: [
            #"{"type":"user","uuid":"u1","entrypoint":"sdk-cli"}"#,
            #"{"type":"assistant","uuid":"a1"}"#
        ])
        try fixture.writeMarker("a1")

        let adapter = ClaudeCodeAdapter(configDirectory: fixture.configDir)
        let dispatch = fixture.dispatch(resume: CLISession(rawValue: sessionID))
        #expect(!adapter.foreignTurns(before: dispatch))
    }

    @Test("Missing transcript reports false")
    func missingTranscriptReportsFalse() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }

        let adapter = ClaudeCodeAdapter(configDirectory: fixture.configDir)
        let dispatch = fixture.dispatch(resume: CLISession(rawValue: "no-such-session"))
        #expect(!adapter.foreignTurns(before: dispatch))
    }

    @Test("Dispatch without resume session reports false")
    func noResumeSessionReportsFalse() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }

        let adapter = ClaudeCodeAdapter(configDirectory: fixture.configDir)
        let dispatch = fixture.dispatch(resume: nil)
        #expect(!adapter.foreignTurns(before: dispatch))
    }

    @Test("Torn last line does not hide earlier valid records")
    func tornLastLineDoesNotHideEarlierRecords() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let sessionID = "sess-torn"
        let projectDir = fixture.projectsDir.appending(
            component: ClaudeCodeAdapter.encodeWorktreePath(fixture.worktreeDir.path(percentEncoded: false)),
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appending(component: "\(sessionID).jsonl")

        let validContent = """
        {"type":"user","uuid":"u1","entrypoint":"sdk-cli"}
        {"type":"assistant","uuid":"a1"}
        {"type":"assistant","uuid":"a2"}
        {"type":"assistant","uuid":"a3"
        """
        try Data(validContent.utf8).write(to: file)
        try fixture.writeMarker("a1")

        let adapter = ClaudeCodeAdapter(configDirectory: fixture.configDir)
        let dispatch = fixture.dispatch(resume: CLISession(rawValue: sessionID))
        #expect(adapter.foreignTurns(before: dispatch))
    }

    @Test("Missing marker file or marker not in transcript checks entrypoint rule only")
    func missingOrUnmatchedMarkerChecksEntrypointOnly() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let sessionID = "sess-no-marker"
        try fixture.writeTranscript(sessionID: sessionID, lines: [
            #"{"type":"user","uuid":"u1","entrypoint":"sdk-cli"}"#,
            #"{"type":"assistant","uuid":"a1"}"#
        ])

        let adapter = ClaudeCodeAdapter(configDirectory: fixture.configDir)
        let dispatch = fixture.dispatch(resume: CLISession(rawValue: sessionID))
        // No marker file written
        #expect(!adapter.foreignTurns(before: dispatch))

        // Marker in file does not match any record in transcript
        try fixture.writeMarker("non-existent-uuid")
        #expect(!adapter.foreignTurns(before: dispatch))

        // With non-matching marker, but foreign entrypoint in user record -> true
        let sessionID2 = "sess-foreign-no-marker"
        try fixture.writeTranscript(sessionID: sessionID2, lines: [
            #"{"type":"user","uuid":"u2","entrypoint":"cli"}"#,
            #"{"type":"assistant","uuid":"a2"}"#
        ])
        let dispatch2 = fixture.dispatch(resume: CLISession(rawValue: sessionID2))
        #expect(adapter.foreignTurns(before: dispatch2))
    }

    @Test("Transcript fallback finds session file when encoded cwd directory does not match")
    func transcriptFallbackToFirstProjectMatch() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let sessionID = "sess-fallback"
        try fixture.writeTranscript(
            sessionID: sessionID,
            lines: [
                #"{"type":"user","uuid":"u1","entrypoint":"cli"}"#
            ],
            customEncodedCwd: "some-other-project-hash"
        )

        let adapter = ClaudeCodeAdapter(configDirectory: fixture.configDir)
        let dispatch = fixture.dispatch(resume: CLISession(rawValue: sessionID))
        #expect(adapter.foreignTurns(before: dispatch))
    }

    @Test("collect records .last-message-id with the uuid of the last turn")
    func collectRecordsLastMessageID() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let sessionID = "sess-collect"
        try fixture.writeTranscript(sessionID: sessionID, lines: [
            #"{"type":"user","uuid":"u1","entrypoint":"sdk-cli"}"#,
            #"{"type":"assistant","uuid":"a1"}"#,
            #"{"type":"queue-operation","uuid":"qo1"}"#
        ])

        let adapter = ClaudeCodeAdapter(configDirectory: fixture.configDir)
        let dispatch = fixture.dispatch(resume: CLISession(rawValue: sessionID))
        let collected = adapter.collect(end: .exited(status: 0), dispatch: dispatch)
        #expect(collected?.rawValue == sessionID)

        let markerFile = fixture.runDir.appending(component: ".last-message-id")
        let recordedMarker = try String(contentsOf: markerFile, encoding: .utf8)
        #expect(recordedMarker == "a1")
    }

    @Test("collect with missing transcript leaves outcome unchanged and writes no marker")
    func collectWithMissingTranscriptWritesNoMarker() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let sessionID = "sess-missing-transcript"

        let adapter = ClaudeCodeAdapter(configDirectory: fixture.configDir)
        let dispatch = fixture.dispatch(resume: CLISession(rawValue: sessionID))
        let collected = adapter.collect(end: .exited(status: 0), dispatch: dispatch)
        #expect(collected?.rawValue == sessionID)

        let markerFile = fixture.runDir.appending(component: ".last-message-id")
        #expect(!FileManager.default.fileExists(atPath: markerFile.path(percentEncoded: false)))
    }

    @Test("Fresh session launch removes stale .last-message-id")
    func freshLaunchRemovesStaleMarker() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        try fixture.writeMarker("old-uuid")
        let markerFile = fixture.runDir.appending(component: ".last-message-id")
        #expect(FileManager.default.fileExists(atPath: markerFile.path(percentEncoded: false)))

        let adapter = ClaudeCodeAdapter(configDirectory: fixture.configDir)
        let dispatch = fixture.dispatch(resume: nil)
        _ = try adapter.launch(for: dispatch)

        #expect(!FileManager.default.fileExists(atPath: markerFile.path(percentEncoded: false)))
    }

    @Test("The transcript root comes from the dispatch environment, never this process's home")
    func transcriptRootComesFromDispatchEnvironment() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let adapter = ClaudeCodeAdapter()
        var dispatch = fixture.dispatch()

        dispatch.environment = [:]
        #expect(adapter.configDirectory(for: dispatch) == nil)

        let home = fixture.tempDir.path(percentEncoded: false)
        dispatch.environment = ["HOME": home]
        #expect(adapter.configDirectory(for: dispatch)
            == fixture.tempDir.appending(component: ".claude", directoryHint: .isDirectory))

        dispatch.environment = ["HOME": home, "CLAUDE_CONFIG_DIR": fixture.configDir.path(percentEncoded: false)]
        #expect(adapter.configDirectory(for: dispatch) == fixture.configDir)
    }

    @Test("A dispatch with no HOME or CLAUDE_CONFIG_DIR records no marker and answers false")
    func noTranscriptRootRecordsNothing() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let sessionID = "sess-no-root"
        try fixture.writeTranscript(sessionID: sessionID, lines: [
            #"{"type":"user","uuid":"u1","entrypoint":"cli"}"#
        ])
        let adapter = ClaudeCodeAdapter()
        var dispatch = fixture.dispatch(resume: CLISession(rawValue: sessionID))
        dispatch.environment = [:]

        #expect(adapter.collect(end: .exited(status: 0), dispatch: dispatch)?.rawValue == sessionID)
        let markerFile = fixture.runDir.appending(component: ".last-message-id")
        #expect(!FileManager.default.fileExists(atPath: markerFile.path(percentEncoded: false)))
        #expect(!adapter.foreignTurns(before: dispatch))
    }

    @Test("A dispatch HOME locates the transcript under its .claude directory")
    func dispatchHomeLocatesTranscript() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let home = fixture.tempDir.appending(component: "home", directoryHint: .isDirectory)
        let projectDir = home.appending(component: ".claude/projects", directoryHint: .isDirectory)
            .appending(component: ClaudeCodeAdapter.encodeWorktreePath(fixture.worktreeDir.path(percentEncoded: false)))
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sessionID = "sess-home"
        try Data(#"{"type":"user","uuid":"u1","entrypoint":"cli"}"#.utf8)
            .write(to: projectDir.appending(component: "\(sessionID).jsonl"))
        let adapter = ClaudeCodeAdapter()
        var dispatch = fixture.dispatch(resume: CLISession(rawValue: sessionID))
        dispatch.environment = ["HOME": home.path(percentEncoded: false)]

        #expect(adapter.foreignTurns(before: dispatch))
    }

    @Test("Codex and Antigravity adapters answer false to foreignTurns")
    func otherAdaptersAnswerFalse() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(resume: CLISession(rawValue: "sess-1"))

        let codex = CodexAdapter()
        let agy = AntigravityAdapter()

        #expect(!codex.foreignTurns(before: dispatch))
        #expect(!agy.foreignTurns(before: dispatch))
    }
}
