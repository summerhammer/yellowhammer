import ArgumentParser
import Domain
import Engine
@testable import EngineCommand
import Foundation
import Testing

// P15.3: YH_REHEARSAL_OUTBOX_KILL is read by makeInvocation only alongside --rehearsal; a real Night
// never even looks at it, and a malformed value fails the invocation before any Act work runs.

@Suite("YH_REHEARSAL_OUTBOX_KILL: read only alongside --rehearsal")
struct OutboxKillEnvironmentTests {
    @Test("Without --rehearsal, the variable is ignored even when malformed")
    func ignoredWithoutRehearsal() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let land = try LandCommand.parse(["--project", "alpha"])

        let invocation = try land.makeInvocation(
            configurationDirectory: directory.url, now: Date(), bindBoard: nil,
            environment: ["YH_REHEARSAL_OUTBOX_KILL": "not-a-valid-spec"]
        )

        #expect(invocation.outboxKill == nil)
    }

    @Test("With --rehearsal, a valid value parses into outboxKill")
    func parsesWithRehearsal() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha", rehearsal: true)
        let land = try LandCommand.parse(["--project", "alpha", "--rehearsal"])

        let invocation = try land.makeInvocation(
            configurationDirectory: directory.url, now: Date(), bindBoard: nil,
            environment: ["YH_REHEARSAL_OUTBOX_KILL": "2"]
        )

        #expect(invocation.outboxKill != nil)
    }

    @Test("With --rehearsal, a malformed value refuses the invocation before any Act work runs")
    func malformedValueRefusedWithRehearsal() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha", rehearsal: true)
        let land = try LandCommand.parse(["--project", "alpha", "--rehearsal"])

        #expect(throws: (any Error).self) {
            try land.makeInvocation(
                configurationDirectory: directory.url, now: Date(), bindBoard: nil,
                environment: ["YH_REHEARSAL_OUTBOX_KILL": "not-a-valid-spec"]
            )
        }
    }

    @Test("With --rehearsal and no variable set, outboxKill is nil")
    func nilWhenUnset() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha", rehearsal: true)
        let land = try LandCommand.parse(["--project", "alpha", "--rehearsal"])

        let invocation = try land.makeInvocation(
            configurationDirectory: directory.url, now: Date(), bindBoard: nil, environment: [:]
        )

        #expect(invocation.outboxKill == nil)
    }
}
