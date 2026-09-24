import ArgumentParser
import Domain
import Engine

/// Parses `--result-fixture <pass>=<fixture>`, shared by `yh rehearse` and the three Act commands. Only
/// valid alongside a Rehearsal Night: a real Night never reads a fixture, so it is never wired to
/// `DispatchBinding.dispatch`.
enum ResultFixtureOption {
    static let help: ArgumentHelp = """
        Answer one pass of a Rehearsal Night from a named fixture instead of the default script \
        (`<pass>=<fixture>`, repeatable). Only valid alongside --rehearsal: a real Night never reads a \
        fixture. <pass> is one of \(RunPass.allCases.map(\.rawValue).joined(separator: ", ")). <fixture> is \
        a bundled fixture name, with or without `.json` (e.g. `worker=worker-question`). Bundled fixtures: \
        \(RehearsalResultFixture.allCases.map(\.rawValue).joined(separator: ", ")).
        """

    /// An Act command's check: refuses any `--result-fixture` without `--rehearsal`, then every entry
    /// ``parse(_:)`` would refuse.
    static func validate(_ raw: [String], rehearsal: Bool) throws {
        guard rehearsal || raw.isEmpty else {
            throw ValidationError(
                "--result-fixture is only valid alongside --rehearsal: a real Night never reads a fixture."
            )
        }
        _ = try parse(raw)
    }

    /// Parses `raw` into `[RunPass: RehearsalResultFixture]`. Refuses an unknown pass, an unknown fixture,
    /// a fixture whose declared pass differs from the pass it is named against, and the same pass given
    /// twice.
    static func parse(_ raw: [String]) throws -> [RunPass: RehearsalResultFixture] {
        var result: [RunPass: RehearsalResultFixture] = [:]
        for entry in raw {
            let (pass, fixture) = try parseEntry(entry)
            guard result[pass] == nil else {
                throw ValidationError("--result-fixture names pass `\(pass.rawValue)` more than once.")
            }
            result[pass] = fixture
        }
        return result
    }

    private static func parseEntry(_ entry: String) throws -> (RunPass, RehearsalResultFixture) {
        let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ValidationError("--result-fixture `\(entry)` must be `<pass>=<fixture>`.")
        }
        let passRaw = String(parts[0])
        let fixtureRaw = String(parts[1])
        guard let pass = RunPass(rawValue: passRaw) else {
            let valid = RunPass.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("--result-fixture names an unknown pass `\(passRaw)`. Valid passes: \(valid).")
        }
        guard let fixture = fixture(named: fixtureRaw) else {
            let valid = RehearsalResultFixture.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError(
                "--result-fixture names an unknown fixture `\(fixtureRaw)`. Valid fixtures: \(valid)."
            )
        }
        guard fixture.pass == pass else {
            throw ValidationError(
                "--result-fixture `\(entry)` names fixture `\(fixture.rawValue)`, whose pass is " +
                "`\(fixture.pass.rawValue)`, not `\(pass.rawValue)`."
            )
        }
        return (pass, fixture)
    }

    private static func fixture(named name: String) -> RehearsalResultFixture? {
        let fileName = name.hasSuffix(".json") ? name : "\(name).json"
        return RehearsalResultFixture(rawValue: fileName)
    }
}
