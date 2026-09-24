import Domain
@testable import EngineCommand
import Engine
import Foundation
import Synchronization
import Testing

@Suite("Rehearse: the three Acts of a Rehearsal Night, in order")
struct RehearseTests {
    private struct StubFailure: Error {}

    @Test("Runs author, build, land in order, each forced, in Rehearsal mode, for the resolved Project")
    func runsAllThreeActsInOrder() async throws {
        let recorded = Mutex<[RehearseActInvocation]>([])
        let output = RecordingOutput()
        let rehearse = Rehearse(
            configurationDirectory: URL(filePath: "/tmp/does-not-matter"),
            output: { output.record($0) },
            runAct: { invocation, _ in recorded.withLock { $0.append(invocation) } }
        )

        try await rehearse.run(projectID: "alpha")

        let invocations = recorded.withLock { $0 }
        #expect(invocations.map(\.act) == [.author, .build, .land])
        #expect(invocations.allSatisfy { $0.project == "alpha" && $0.force && $0.rehearsal })
        #expect(output.lines.contains("rehearsal Night: running the author Act"))
        #expect(output.lines.contains("rehearsal Night: running the build Act"))
        #expect(output.lines.contains("rehearsal Night: running the land Act"))
    }

    @Test("Stops at the first Act that throws; later Acts never run")
    func stopsOnFirstFailure() async throws {
        let recorded = Mutex<[RehearseActInvocation]>([])
        let output = RecordingOutput()
        let rehearse = Rehearse(
            configurationDirectory: URL(filePath: "/tmp/does-not-matter"),
            output: { output.record($0) },
            runAct: { invocation, _ in
                recorded.withLock { $0.append(invocation) }
                if invocation.act == .build { throw StubFailure() }
            }
        )

        await #expect(throws: StubFailure.self) {
            try await rehearse.run(projectID: "alpha")
        }

        let invocations = recorded.withLock { $0 }
        #expect(invocations.map(\.act) == [.author, .build])
        #expect(output.lines.contains("rehearsal Night: the build Act failed"))
        #expect(!output.lines.contains { $0.contains("land Act") })
    }

    @Test(
        "The real seam builds each Act's command as `yh <act> --project --force --rehearsal` would",
        arguments: [Act.author, .build, .land]
    )
    func realSeamBuildsParsedCommands(act: Act) throws {
        let invocation = RehearseActInvocation(act: act, project: "alpha", force: true, rehearsal: true)

        let command = try Rehearse.command(for: invocation)

        #expect(type(of: command).act == act)
        #expect(command.project == "alpha")
        #expect(command.force)
        #expect(command.rehearsal)
        // Reads every option, AuthorCommand's `--feature` included: an undecoded one traps here.
        #expect(try command.makeTrigger() == .forced)
    }

    @Test("arguments forwards --result-fixture pairs, sorted by pass raw value, for a deterministic order")
    func argumentsForwardsResultFixturesSorted() {
        let invocation = RehearseActInvocation(
            act: .build, project: "alpha", force: true, rehearsal: true,
            resultFixtures: [.reviewer: .reviewerChangesRequested, .architect: .architectFailed]
        )

        #expect(invocation.arguments == [
            "--project", "alpha", "--force", "--rehearsal",
            "--result-fixture", "architect=architect-failed.json",
            "--result-fixture", "reviewer=reviewer-changes-requested.json"
        ])
    }

    @Test("Rehearse.run forwards the same fixtures to every Act's invocation")
    func runForwardsFixturesToEveryAct() async throws {
        let recorded = Mutex<[RehearseActInvocation]>([])
        let rehearse = Rehearse(
            configurationDirectory: URL(filePath: "/tmp/does-not-matter"),
            output: { _ in },
            runAct: { invocation, _ in recorded.withLock { $0.append(invocation) } }
        )
        let fixtures: [RunPass: RehearsalResultFixture] = [.worker: .workerQuestion]

        try await rehearse.run(projectID: "alpha", resultFixtures: fixtures)

        let invocations = recorded.withLock { $0 }
        #expect(invocations.allSatisfy { $0.resultFixtures == fixtures })
    }

    @Test("Rehearse.command(for:) round-trips forwarded fixtures into each Act command")
    func commandRoundTripsForwardedFixtures() throws {
        let invocation = RehearseActInvocation(
            act: .build, project: "alpha", force: true, rehearsal: true,
            resultFixtures: [.worker: .workerQuestion]
        )

        let command = try Rehearse.command(for: invocation)

        #expect(command.resultFixtures == [.worker: .workerQuestion])
    }
}
