import Domain
import Foundation

/// One Act of a Rehearsal Night, exactly as `yh <act> --project <id> --force --rehearsal` would run it.
/// A value, not a live command, so a test can inspect what ``Rehearse`` built without running an Act.
struct RehearseActInvocation: Equatable {
    let act: Act
    let project: String
    let force: Bool
    let rehearsal: Bool
}

/// `yh rehearse`'s orchestration: the author, build and land Acts, in that order, each through the same
/// `ActCommand.run(configurationDirectory:)` path its own `yh <act>` invocation would take — its own
/// `EngineInvocation`, its own Act-scoped Lease. Stops at the first Act that throws; later Acts do not
/// run. The act-runner is a seam so a test can assert order and flags without dispatching a real Act.
struct Rehearse {
    let configurationDirectory: URL
    let output: (String) -> Void
    let runAct: (RehearseActInvocation, URL) async throws -> Void

    init(
        configurationDirectory: URL,
        output: @escaping (String) -> Void,
        runAct: @escaping (RehearseActInvocation, URL) async throws -> Void = Rehearse.runRealAct
    ) {
        self.configurationDirectory = configurationDirectory
        self.output = output
        self.runAct = runAct
    }

    /// The real seam: builds and runs the ordinary `ActCommand` for `invocation.act`, forced and in
    /// Rehearsal mode — no new invocation path, no change to `closesNight` or clock logic.
    static func runRealAct(_ invocation: RehearseActInvocation, configurationDirectory: URL) async throws {
        switch invocation.act {
        case .author:
            var command = AuthorCommand()
            command.project = invocation.project
            command.force = invocation.force
            command.rehearsal = invocation.rehearsal
            try await command.run(configurationDirectory: configurationDirectory)
        case .build:
            var command = BuildCommand()
            command.project = invocation.project
            command.force = invocation.force
            command.rehearsal = invocation.rehearsal
            try await command.run(configurationDirectory: configurationDirectory)
        case .land:
            var command = LandCommand()
            command.project = invocation.project
            command.force = invocation.force
            command.rehearsal = invocation.rehearsal
            try await command.run(configurationDirectory: configurationDirectory)
        }
    }

    /// Runs the author, build and land Acts in order for `projectID` (already resolved). Prints a line
    /// before and after each Act; on failure, prints which Act failed and rethrows without running the
    /// Acts still queued.
    func run(projectID: String) async throws {
        for act in [Act.author, .build, .land] {
            output("rehearsal Night: running the \(act.rawValue) Act")
            let invocation = RehearseActInvocation(act: act, project: projectID, force: true, rehearsal: true)
            do {
                try await runAct(invocation, configurationDirectory)
            } catch {
                output("rehearsal Night: the \(act.rawValue) Act failed")
                throw error
            }
            output("rehearsal Night: the \(act.rawValue) Act finished")
        }
    }
}
