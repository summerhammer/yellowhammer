import Domain
@testable import EngineCommand
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
}
