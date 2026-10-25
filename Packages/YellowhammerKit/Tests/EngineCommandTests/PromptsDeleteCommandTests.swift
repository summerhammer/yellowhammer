import ArgumentParser
import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

private final class OutputCollector: @unchecked Sendable {
    var lines: [String] = []
    func record(_ line: String) {
        lines.append(line)
    }
}

private func makePromptRecord(
    id: String, family: PromptFamily, projectID: String?, dispatchedAt: Date = Date()
) -> DispatchPromptRecord {
    let provenance = DispatchProvenance(
        recordID: id,
        family: family,
        projectID: projectID
    )
    return DispatchPromptRecord(
        provenance: provenance,
        route: "claude / opus / high",
        pass: .worker,
        dispatchedAt: dispatchedAt,
        defaultVersion: 1,
        projectInstructions: .absent,
        session: .new,
        instruction: "Test prompt instruction",
        outputSchema: "{}",
        launch: .launched
    )
}

@Suite("yh prompts delete")
struct PromptsDeleteCommandTests {
    @Test("Deletes existing record, reports already deleted for missing, and prints exact expected lines")
    func deleteProjectRecordsOutputs() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let storeRoot = DispatchPromptStore.rootDirectory(configurationDirectory: directory.url)
        let store = DispatchPromptStore(rootDirectory: storeRoot)
        let record = makePromptRecord(id: "rec-1", family: .worker, projectID: "alpha")
        _ = store.capture(record)

        let parsed = try RootCommand.parseAsRoot(["prompts", "delete", "--project", "alpha", "rec-1", "rec-2"])
        let command = try #require(parsed as? PromptsDeleteCommand)

        let output = OutputCollector()
        try await command.run(configurationDirectory: directory.url, output: { output.record($0) })

        #expect(output.lines == [
            "deleted rec-1",
            "already deleted rec-2"
        ])

        // Second run: both are already deleted
        let output2 = OutputCollector()
        try await command.run(configurationDirectory: directory.url, output: { output2.record($0) })

        #expect(output2.lines == [
            "already deleted rec-1",
            "already deleted rec-2"
        ])
    }

    @Test("Deletes machine-scoped prompt record with --machine flag")
    func deleteMachineRecordsOutputs() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let storeRoot = DispatchPromptStore.rootDirectory(configurationDirectory: directory.url)
        let store = DispatchPromptStore(rootDirectory: storeRoot)
        let record = makePromptRecord(id: "rec-m1", family: .unattendedProbe, projectID: nil)
        _ = store.capture(record)

        let parsed = try RootCommand.parseAsRoot(["prompts", "delete", "--machine", "rec-m1"])
        let command = try #require(parsed as? PromptsDeleteCommand)

        let output = OutputCollector()
        try await command.run(configurationDirectory: directory.url, output: { output.record($0) })

        #expect(output.lines == ["deleted rec-m1"])
    }

    @Test("Reports failed lines and exits non-zero (ExitCode 1) when any id fails")
    func deleteWithFailedIDExitsNonZero() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let storeRoot = DispatchPromptStore.rootDirectory(configurationDirectory: directory.url)
        let store = DispatchPromptStore(rootDirectory: storeRoot)
        let record = makePromptRecord(id: "rec-good", family: .worker, projectID: "alpha")
        _ = store.capture(record)

        let parsed = try RootCommand.parseAsRoot(["prompts", "delete", "--project", "alpha", "rec-good", "../bad-id"])
        let command = try #require(parsed as? PromptsDeleteCommand)

        let output = OutputCollector()
        await #expect(throws: ExitCode(1)) {
            try await command.run(configurationDirectory: directory.url, output: { output.record($0) })
        }

        #expect(output.lines.count == 2)
        #expect(output.lines[0] == "deleted rec-good")
        #expect(output.lines[1].hasPrefix("failed ../bad-id:"))
    }
}
