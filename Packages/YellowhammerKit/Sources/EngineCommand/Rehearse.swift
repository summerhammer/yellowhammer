import Domain
import Engine
import Foundation

/// One Act of a Rehearsal Night, exactly as `yh <act> --project <id> --force --rehearsal` would run it.
/// A value, not a live command, so a test can inspect what ``Rehearse`` built without running an Act.
struct RehearseActInvocation: Equatable {
    let act: Act
    let project: String
    let force: Bool
    let rehearsal: Bool
    let night: NightStart?
    let resultFixtures: RehearsalScript

    init(
        act: Act, project: String, force: Bool, rehearsal: Bool, night: NightStart? = nil,
        resultFixtures: RehearsalScript = RehearsalScript.empty
    ) {
        self.act = act
        self.project = project
        self.force = force
        self.rehearsal = rehearsal
        self.night = night
        self.resultFixtures = resultFixtures
    }
}

extension RehearseActInvocation {
    /// The arguments `yh <act>` receives for this invocation. `--night` comes after `--rehearsal` and
    /// before `--result-fixture`; by-pass fixtures are forwarded first, sorted by pass raw value, then
    /// Card-scoped fixtures, sorted by (Card issue id, pass raw value) — a deterministic order, so the
    /// emitted arguments are stable across runs.
    var arguments: [String] {
        let sortedByCard = resultFixtures.byCard.sorted {
            ($0.key.issueID, $0.key.pass.rawValue) < ($1.key.issueID, $1.key.pass.rawValue)
        }
        var arguments: [String] = ["--project", project]
        if force { arguments.append("--force") }
        if rehearsal { arguments.append("--rehearsal") }
        if let night { arguments += ["--night", night.rawValue] }
        for (pass, fixture) in resultFixtures.byPass.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            arguments += ["--result-fixture", "\(pass.rawValue)=\(fixture.rawValue)"]
        }
        for (key, fixture) in sortedByCard {
            arguments += ["--result-fixture", "\(key.pass.rawValue)@\(key.issueID)=\(fixture.rawValue)"]
        }
        return arguments
    }
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
        try await command(for: invocation).run(configurationDirectory: configurationDirectory)
    }

    /// The `ActCommand` `yh <act>` would build from `invocation.arguments`. Parsed, never built with
    /// `init()` and assigned: a property wrapper left undecoded (AuthorCommand's `--feature`) traps
    /// on first read, and parsing also runs the command's `validate()`, as the CLI path does.
    static func command(for invocation: RehearseActInvocation) throws -> any ActCommand {
        switch invocation.act {
        case .author: try AuthorCommand.parse(invocation.arguments)
        case .build: try BuildCommand.parse(invocation.arguments)
        case .land: try LandCommand.parse(invocation.arguments)
        }
    }

    /// Runs the author, build and land Acts in order for `projectID` (already resolved). Prints a line
    /// before and after each Act; on failure, prints which Act failed and rethrows without running the
    /// Acts still queued. `resultFixtures` is forwarded, unchanged, to every Act. `night`, when given,
    /// is forwarded to every Act too — the rehearsal-only `--night` (P15.3), letting a suite run several
    /// successive Nights in one session.
    func run(
        projectID: String, resultFixtures: RehearsalScript = RehearsalScript.empty, night: NightStart? = nil
    ) async throws {
        for act in [Act.author, .build, .land] {
            output("rehearsal Night: running the \(act.rawValue) Act")
            let invocation = RehearseActInvocation(
                act: act, project: projectID, force: true, rehearsal: true, night: night,
                resultFixtures: resultFixtures
            )
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
