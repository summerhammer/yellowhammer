import Config
import Domain
import Foundation
import Testing

@testable import Pulse

@Suite("DispatchPromptIndex: a Probe Result opens its own run")
struct PromptIndexProbeRunTests {
    private func seed(
        _ store: DispatchPromptStore, id: String, runID: String, family: PromptFamily, at time: Date,
        route: String = "claude/sonnet/medium"
    ) {
        let record = DispatchPromptRecord(
            id: id,
            provenance: DispatchProvenance(recordID: id, family: family, runID: runID),
            route: route,
            pass: .architect,
            dispatchedAt: time,
            defaultVersion: 1,
            projectInstructions: .absent,
            session: .new,
            instruction: "Probe \(id)",
            outputSchema: nil,
            launch: .launched
        )
        #expect(store.capture(record) == .recorded(id: id))
    }

    private func seedTwoRuns(_ store: DispatchPromptStore) {
        seed(store, id: "old-a", runID: "run-old", family: .unattendedProbe, at: epoch)
        seed(store, id: "old-b", runID: "run-old", family: .sessionResumptionProbe, at: epoch.addingTimeInterval(1))
        seed(store, id: "new-a", runID: "run-new", family: .unattendedProbe, at: epoch.addingTimeInterval(100))
    }

    private func read(_ store: DispatchPromptStore, runID: String?) throws -> DispatchPromptIndex {
        try DispatchPromptIndex.read(
            journal: nil, store: store, projectID: nil,
            scope: .machine(runID: runID, cli: "claude"), asOf: epoch.addingTimeInterval(200)
        )
    }

    @Test("The older run requested by id returns only its own items, not the newer run's")
    func olderRunByID() throws {
        let fixture = PromptIndexFixture()
        let store = fixture.makeStore()
        seedTwoRuns(store)

        let index = try read(store, runID: "run-old")

        #expect(index.emptyState == nil)
        #expect(index.items.map(\.id) == ["old-a", "old-b"])
    }

    @Test("A record deleted through the store stays in its run as a deleted item")
    func deletedRecordStaysInItsRun() throws {
        let fixture = PromptIndexFixture()
        let store = fixture.makeStore()
        seedTwoRuns(store)
        #expect(store.delete(ids: ["old-b"], in: .machine) == [.deleted])

        let index = try read(store, runID: "run-old")

        #expect(index.items.map(\.id) == ["old-a", "old-b"])
        let deleted = try #require(index.items.last)
        guard case .deleted = deleted.state else {
            Issue.record("Expected .deleted, got \(deleted.state)")
            return
        }
        #expect(deleted.family == .sessionResumptionProbe)
        #expect(deleted.time == epoch.addingTimeInterval(1))
        #expect(deleted.instruction == nil)
        #expect(deleted.outputSchema == nil)
    }

    @Test("A run whose records were all deleted still opens, with the CLI filter as its cli")
    func fullyDeletedRunKeepsItsCLI() throws {
        let fixture = PromptIndexFixture()
        let store = fixture.makeStore()
        seedTwoRuns(store)
        #expect(store.delete(ids: ["old-a", "old-b"], in: .machine) == [.deleted, .deleted])

        let runs = DispatchPromptIndex.machine(store: store, cli: "claude", asOf: epoch.addingTimeInterval(200))
        let old = try #require(runs.first { $0.runID == "run-old" })

        #expect(old.cli == "claude")
        #expect(old.items.count == 2)
    }

    @Test("A deleted run of another CLI is not listed under a CLI filter")
    func deletedRunOfAnotherCLIIsFiltered() throws {
        let fixture = PromptIndexFixture()
        let store = fixture.makeStore()
        seedTwoRuns(store)
        seed(store, id: "codex-a", runID: "run-codex", family: .unattendedProbe, at: epoch.addingTimeInterval(150),
             route: "codex/gpt-5.4/medium")
        #expect(store.delete(ids: ["codex-a"], in: .machine) == [.deleted])

        let runs = DispatchPromptIndex.machine(store: store, cli: "claude", asOf: epoch.addingTimeInterval(200))

        #expect(runs.map(\.runID) == ["run-new", "run-old"])
    }

    @Test("A requested run with no retained records returns the empty index, never the newer run")
    func unknownRunIsEmptyNotNewest() throws {
        let fixture = PromptIndexFixture()
        let store = fixture.makeStore()
        seedTwoRuns(store)

        let index = try read(store, runID: "run-gone")

        #expect(index.items.isEmpty)
        #expect(index.emptyState == .probeRecordsNotRetained)
    }
}
